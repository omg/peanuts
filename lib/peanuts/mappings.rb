require 'forwardable'
require 'peanuts/converters'

module Peanuts
  class Mapping
    attr_reader :xmlname, :xmlns, :prefix, :options

    def initialize(xmlname, options)
      @xmlname, @xmlns, @prefix, @options = xmlname.to_s, options.delete(:xmlns), options.delete(:prefix), options
    end

    def self.node_type(node_type)
      define_method(:node_type) { node_type }
    end
  end

  module Mappings
    class Root < Mapping
      node_type :element

      def save(writer, &block)
        writer.write(node_type, xmlname, xmlns, prefix, &block)
      end
    end

    class MemberMapping < Mapping
      attr_reader :name, :type, :converter

      def initialize(name, type, options)
        @bare_name = name.to_s.sub(/\?\z/, '')

        super(options.delete(:xmlname) || @bare_name, options)

        @converter = case type
        when Symbol
          Converter.create!(type, options)
        when Class
          type < Converter && Converter.create!(type, options)
        when Array
          raise ArgumentError, "invalid value for type: #{type.inspect}" if type.length != 1
          options[:item_type] = type.first
          Converter.create!(:list, options)
        else
          raise ArgumentError, "invalid value for type: #{type.inspect}"
        end
        @name, @setter, @type = name.to_sym, :"#{@bare_name}=", type
      end

      def define_accessor(type)
        raise ArgumentError, "#{name}: method already defined or reserved" if type.method_defined?(name)
        raise ArgumentError, "#{@setter}: method already defined or reserved" if type.method_defined?(@setter)

        type.class_eval <<-DEF
          def #{name}; @#{@bare_name}; end
          def #{@setter}(value); @#{@bare_name} = value; end
        DEF
      end

      def save(nut, writer)
        save_value(writer, get(nut))
      end

      def restore(nut, reader)
        set(nut, restore_value(reader, get(nut)))
      end

      def clear(nut)
        set(nut, nil)
      end

      private
      def get(nut)
        nut.send(@name)
      end

      def set(nut, value)
        nut.send(@setter, value)
      end

      def to_xml(value)
        @converter ? @converter.to_xml(value) : value
      end

      def from_xml(text)
        @converter ? @converter.from_xml(text) : text
      end

      def write(writer, &block)
        writer.write(node_type, xmlname, xmlns, prefix, &block)
      end
    end

    module SingleMapping
      private
      def restore_value(reader, acc)
        read_value(reader)
      end

      def save_value(writer, value)
        write(writer) {|w| write_value(w, value) }
      end
    end

    module MultiMapping
      def restore_value(reader, acc)
        (acc || []) << read_value(reader)
      end

      def save_value(writer, values)
        values.each {|value| write(writer) {|w| write_value(w, value) } } if values
      end
    end

    module ValueMapping
      private
      def read_value(reader)
        from_xml(reader.value)
      end

      def write_value(writer, value)
        writer.value = to_xml(value)
      end
    end

    module ObjectMapping
      private
      def read_value(reader)
        type.send(:_restore, reader)
      end

      def write_value(writer, value)
        type.send(:_save, value, writer)
      end
    end

    module ShallowMapping
      def restore(nut, reader)
        type.send(:_restore, reader, nut)
      end

      def save(nut, writer)
        write(writer) {|w| type.send(:_save, nut, w) }
      end

      def define_accessor(type)
        type.mapper.each {|m| m.define_accessor(type) }
      end
    end

    class ElementValue < MemberMapping
      include SingleMapping
      include ValueMapping

      node_type :element
    end

    class Element < MemberMapping
      include SingleMapping
      include ObjectMapping

      node_type :element
    end

    class Attribute < MemberMapping
      include SingleMapping
      include ValueMapping

      node_type :attribute

      def initialize(name, type, options)
        super
        raise ArgumentError, 'a namespaced attribute must have namespace prefix' if xmlns && !prefix
      end
    end

    class ElementValues < MemberMapping
      include MultiMapping
      include ValueMapping

      node_type :element
    end

    class Elements < MemberMapping
      include MultiMapping
      include ObjectMapping

      node_type :element
    end

    class ShallowElement < Element
      include ShallowMapping
    end
  end
end
