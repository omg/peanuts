# encoding: UTF-8

require 'libxml'
require 'forwardable'
require 'uri'
require 'stringio'
require 'peanuts/xml'

module Peanuts
  module XML
    module LibXML
      def self.libxml_opt(options, default = {})
        h = default.merge(options)
        h.update(h.from_namespace!(:libxml))
      end

      class Writer < Peanuts::XML::Writer
        DEFAULT_OPTIONS = {}

        def initialize(dest, options = {})
          @dest = case dest
          when :string
            ''
          when :document
            ::LibXML::XML::Document.new
          when ::LibXML::XML::Document
            dest
          else
            raise ArgumentError, "unsupported destination #{dest.inspect}" unless dest.respond_to?(:<<)
            dest
          end
          @options = LibXML.libxml_opt(options, DEFAULT_OPTIONS)
        end

        def result
          @dest
        end

        def write_value(value)
          case @node
          when ::LibXML::XML::Attr
            @node.value = value || ''
          else
            @node.content = value || ''
          end
        end

        def write_namespaces(namespaces)
          for prefix, uri in namespaces
            mkns(@node, uri, prefix)
          end
        end

        def write(node_type, local_name = nil, namespace_uri = nil, prefix = nil)
          case node_type
          when :element
            @node = ::LibXML::XML::Node.new(local_name)
            @parent << @node if @parent
            if namespace_uri || prefix
              unless namespace_uri
                defns = @node.namespaces.default
                namespace_uri = defns ? defns.href : ''
              end
              @node.namespaces.namespace = mkns(@node, namespace_uri, prefix)
            end
          when :attribute
            @node = ::LibXML::XML::Attr.new(@parent, local_name, '', namespace_uri && mkns(@parent, namespace_uri, prefix))
          else
            raise "unsupported node type #{node_type.inspect}"
          end

          exparent, @parent = @parent, @node

          yield self

          if exparent.nil?
            case @dest
            when ::LibXML::XML::Document
              @dest.root = @parent
            else
              @dest << @parent.to_s(@options)
            end
          end

          @parent = exparent
        end

        private
        def mkns(node, namespace_uri, prefix)
          prefix = nil if prefix && (prefix = prefix.to_s).empty?
          newns = proc { ::LibXML::XML::Namespace.new(node, prefix, namespace_uri) }
          node.namespaces.find(newns) {|ns| ns.prefix == prefix && ns.href == namespace_uri }
        end
      end

      class Reader < Peanuts::XML::Reader
        extend Forwardable

        SCHEMAS = {:xml_schema => :schema, :relax_ng => :relax_ng}

        RD = ::LibXML::XML::Reader

        NODE_TYPES = [
          nil,
          :element,
          :attribute,
          :text,
          :cdata,
          :entity_reference,
          :entity,
          :processing_instruction,
          :comment,
          :document,
          :document_type,
          :document_fragment,
          :notation,
          :whitespace,
          :significant_whitespace,
          :end_element,
          :end_entity,
          :xml_declaration
        ].freeze

        DEFAULT_OPTIONS = {}

        def initialize(source, options = {})
          super()
          options = options.dup
          @schema = options.delete(:schema)
          options = LibXML.libxml_opt(options, DEFAULT_OPTIONS)
          @reader = case source
          when String
            RD.string(source.to_s, options)
          when URI
            RD.file(source.to_s, options)
          when ::LibXML::XML::Document
            RD.document(source)
          else
            raise "unsupported source #{source.inspect}" unless source.respond_to?(:read)
            RD.io(source, options)
          end
          @reader.send("#{SCHEMAS[schema.type]}_validate", schema.schema) if @schema
        end

        def close
          @reader.close
        end

        def_delegators :@reader, :name, :local_name, :namespace_uri, :depth

        def node_type
          NODE_TYPES[@reader.node_type]
        end

        def value
          case @reader.node_type
          when RD::TYPE_ELEMENT
            _string(@reader.read_string)
          else
            @reader.has_value? ? _string(@reader.value) : nil
          end
        end

        def each
          depth = self.depth
          if read
            while self.depth > depth
              yield self
              break unless next_sibling
            end
          end
        end

        def find_element
          until @reader.node_type == RD::TYPE_ELEMENT
            return nil unless read
          end
          self
        end

        private
        if ''.respond_to?(:force_encoding)
          def _string(v)
            v.force_encoding(Encoding::UTF_8)
          end
        else
          def _string(v)
            v
          end
        end

        def read
          case @reader.node_type
          when RD::TYPE_ATTRIBUTE
            @reader.move_to_next_attribute > 0 || @reader.read
          else
            @reader.move_to_first_attribute > 0 || @reader.read
          end
        end

        def next_sibling
          case @reader.node_type
          when RD::TYPE_ATTRIBUTE
            @reader.move_to_next_attribute > 0 || @reader.read
          else
            @reader.next > 0
          end
        end
      end

      def self.schema(schema_type, source)
        schema_class = case schema_type
        when :xml_schema
          ::LibXML::XML::Schema
        when :relax_ng
          ::LibXML::XML::RelaxNG
        else
          raise ArgumentError, "unrecognized schema type #{schema_type}"
        end
        schema = case source
        when IO
          schema_class.string(source.read)
        when URI
          schema_class.new(source.to_s)
        when ::LibXML::XML::Document
          schema_class.document(source)
        else
          schema_class.string(source)
        end

        Schema.new(schema_type, schema)
      end

      class Schema
        attr_reader :type, :handle

        def initialize(type, handle)
          @type, @handle = type, handle
        end
      end
    end
  end
end
