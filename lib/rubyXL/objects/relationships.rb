require 'rubyXL/objects/ooxml_object'

module RubyXL

  class RID < OOXMLObject
    define_attribute(:'r:id',            :string, :required => true)
  end

  class Relationship < OOXMLObject
    define_attribute(:Id,         :string)
    define_attribute(:Type,       :string)
    define_attribute(:Target,     :string)
    define_attribute(:TargetMode, :string)
    define_element_name 'Relationship'
  end

  class OOXMLRelationshipsFile < OOXMLTopLevelObject
    CONTENT_TYPE = 'application/vnd.openxmlformats-package.relationships+xml'
    SAVE_ORDER = 100

    define_child_node(RubyXL::Relationship, :collection => true, :accessor => :relationships)
    define_element_name 'Relationships'
    set_namespaces('http://schemas.openxmlformats.org/package/2006/relationships' => '')

    attr_accessor :related_files, :owner

    @@debug = nil # Change to 0 to enable debug output

    def new_relationship(target, type)
      RubyXL::Relationship.new(:id => "rId#{relationships.size + 1}",
                               :type => type,
                               :target => target)
    end
    protected :new_relationship

    def add_relationship(obj)
      return if obj.nil? || !defined?(obj.class::REL_TYPE)
      relationships << RubyXL::Relationship.new(:id => "rId#{relationships.size + 1}",
                                                :type => obj.class::REL_TYPE,
                                                :target => obj.xlsx_path.relative_path_from(owner.xlsx_path.dirname))
    end
    protected :add_relationship

    def find_by_rid(r_id)
      relationships.find { |r| r.id == r_id }
    end

    def find_by_target(target)
      relationships.find { |r|
        (r.target == target) || (r.target == target.relative_path_from(owner.xlsx_path.dirname))
      }
    end

    def self.get_class_by_rel_type(rel_type)
      unless defined?(@@rel_hash)
        @@rel_hash = {}
        RubyXL.constants.each { |c|
          klass = RubyXL.const_get(c)

          if klass.is_a?(Class) && klass.const_defined?(:REL_TYPE) then
            @@rel_hash[klass::REL_TYPE] = klass
          end
        }
      end

      @@rel_hash[rel_type]
    end

    def load_related_files(zipdir_path, base_file_name)
      self.related_files = {}

      @@debug +=2 if @@debug

      self.relationships.each { |rel|
        next if rel.target_mode == 'External'

        file_path = ::Pathname.new(rel.target)
        file_path = (base_file_name.dirname + file_path).cleanpath if file_path.relative?

        klass = RubyXL::OOXMLRelationshipsFile.get_class_by_rel_type(rel.type)

        if klass.nil? then
          puts "*** WARNING: storage class not found for #{rel.target} (#{rel.type})"
          klass = GenericStorageObject
        end

        puts "--> DEBUG:#{'  ' * @@debug}Loading #{klass} (#{rel.id}): #{file_path}" if @@debug

        obj = klass.parse_file(zipdir_path, file_path)
        obj.load_relationships(zipdir_path, file_path) if obj.respond_to?(:load_relationships)
        self.related_files[rel.id] = obj
      }

      @@debug -=2 if @@debug

      related_files
    end

    def self.load_relationship_file(zipdir_path, base_file_path)
      rel_file_path = rel_file_path(base_file_path)

      puts "--> DEBUG:  #{'  ' * @@debug}Loading .rel file: #{rel_file_path}" if @@debug

      parse_file(zipdir_path, rel_file_path)
    end

    def xlsx_path
      self.class.rel_file_path(owner.xlsx_path)
    end

    def before_write_xml
      case owner
      when RubyXL::WorkbookRoot, RubyXL::Workbook then
        # Fully implemented objects with no generic (unhandled) relationships -
        #   (re)generating relationships from scratch.
        related_objects = owner.related_objects
        related_objects += owner.generic_storage if owner.generic_storage

        self.relationships = []
        related_objects.compact.each { |f| add_relationship(f) }
      end
      super
    end

    def self.rel_file_path(base_file_path)
      basename = base_file_path.root? ? '' : base_file_path.basename
      base_file_path.dirname.join('_rels', "#{basename}.rels").cleanpath
    end

  end


  module RelationshipSupport

    module ClassMehods
      def define_relationship(klass, accessor = nil)
        class_variable_get(:@@ooxml_relationships)[klass] = accessor
        attr_accessor(accessor) if accessor
      end
    end

    def self.included(klass)
      klass.class_variable_set(:@@ooxml_relationships, {})
      klass.extend RubyXL::RelationshipSupport::ClassMehods
    end

    attr_accessor :generic_storage, :relationship_container

    def related_objects # Override this method
      []
    end

    def collect_related_objects
      res = related_objects.compact # Avoid tainting +related_objects+ array
      res += generic_storage if generic_storage

      if relationship_container then
        relationship_container.owner = self
        res << relationship_container
      end

      res.each { |o| res += o.collect_related_objects if o.respond_to?(:collect_related_objects) }

      res
    end

    def load_relationships(dir_path, base_file_name)
      self.relationship_container = RubyXL::OOXMLRelationshipsFile.load_relationship_file(dir_path, base_file_name)
      return if relationship_container.nil?

      relationship_container.load_related_files(dir_path, base_file_name).each_pair { |rid, related_file|
        attach_relationship(rid, related_file) if related_file
      }
    end

    def attach_relationship(rid, rf)
      relationships = self.class.class_variable_get(:@@ooxml_relationships)
      klass = rf.class
      if relationships.has_key?(klass) then
        accessor = relationships[klass]
        case accessor
        when NilClass then
          # Relationship is known, but we don't have a special accessor for it, store as generic
          store_relationship(rf)
        when false then
          # Do nothing, the code will perform attaching on its own
        else
          container = self.send(accessor)
          if container.is_a?(Array) then container << rf
          else self.send("#{accessor}=", rf)
          end
        end
      else store_relationship(rf, :unknown)
      end
    end

    def store_relationship(related_file, unknown = false)
      self.generic_storage ||= []
      puts "WARNING: #{self.class} is not aware what to do with #{related_file.class}" if unknown
      self.generic_storage << related_file
    end

  end

end
