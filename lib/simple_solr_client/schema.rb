require 'nokogiri'

require 'simple_solr_client/schema/matcher'
require 'simple_solr_client/schema/copyfield'
require 'simple_solr_client/schema/field'
require 'simple_solr_client/schema/dynamic_field'
require 'simple_solr_client/schema/field_type'

class SimpleSolrClient::Schema
  # A simplistic representation of a schema


  attr_reader :xmldoc

  def initialize(core)
    @core           = core
    @fields         = {}
    @dynamic_fields = {}
    @copy_fields    = Hash.new { |h, k| h[k] = [] }
    @field_types    = {}
    self.load
  end


  def fields
    @fields.values.map { |x| x.resolve_type(self) }
  end

  def field(n)
    @fields[n].resolve_type(self)
  end

  def dynamic_fields
    @dynamic_fields.values.map { |x| x.resolve_type(self) }
  end

  def dynamic_field(n)
    @dynamic_fields[n].resolve_type(self)
  end

  def copy_fields_for(n)
    @copy_fields[n]
  end

  def copy_fields
    @copy_fields.values.flatten
  end

  def add_field(f)
    @fields[f.name] = f
    field(f.name)
  end

  def drop_field(str)
    @fields.delete(str)
    self
  end


  def field_types
    @field_types.values
  end

  def field_type(k)
    @field_types[k]
  end


  # When we add dynamic fields, we need to keep them sorted by
  # length of the key, since that's how they match
  def add_dynamic_field(f)
    raise "Dynamic field should be dynamic and have a '*' in it somewhere; '#{f.name}' does not" unless f.name =~ /\*/
    @dynamic_fields[f.name] = f

    @dynamic_fields = @dynamic_fields.sort { |a, b| b[0].size <=> a[0].size }.to_h

  end

  def drop_dynamic_field(str)
    @dynamic_fields.delete(str)
    self
  end

  def add_copy_field(f)
    cf = @copy_fields[f.source]
    cf << f
  end

  def drop_copy_field(str)
    @copy_fields.delete(str)
    self
  end

  def add_field_type(ft)
    ft.core = @core
    @field_types[ft.name] = ft
  end

  def drop_field_type(str)
    @field_types.delete(str)
    self
  end


  # For loading, we get the information about the fields via the API,
  # but grab an XML document for modifying/writing
  def load
    @xmldoc = Nokogiri.XML(@core.raw_get_content('admin/file', {:file => 'schema.xml'})) do |config|
      config.noent
    end
    load_explicit_fields
    load_dynamic_fields
    load_copy_fields
    load_field_types
  end


  def load_explicit_fields
    @fields = {}
    @core.get('schema/fields')['fields'].each do |field_hash|
      add_field(Field.new_from_solr_hash(field_hash))
    end
  end

  def load_dynamic_fields
    @dynamic_fields = {}
    @core.get('schema/dynamicfields')['dynamicFields'].each do |field_hash|
      f = DynamicField.new_from_solr_hash(field_hash)
      if @dynamic_fields[f.name]
        raise "Dynamic field '#{f.name}' defined more than once"
      end
      add_dynamic_field(f)
    end
  end

  def load_copy_fields
    @copy_fields = Hash.new { |h, k| h[k] = [] }
    @core.get('schema/copyfields')['copyFields'].each do |cfield_hash|
      add_copy_field(CopyField.new(cfield_hash['source'], cfield_hash['dest']))
    end
  end

  def load_field_types
    @field_types = {}
    @core.get('schema/fieldtypes')['fieldTypes'].each do |fthash|
      ft        = FieldType.new_from_solr_hash(fthash)
      type_name = ft.name
      attr      = "[@name=\"#{type_name}\"]"
      node      = @xmldoc.css("fieldType#{attr}").first || @xmldoc.css("fieldtype#{attr}").first
      unless node
        puts "Failed for type #{type_name}"
      end
      ft.xml    = node.to_xml
      add_field_type(ft)
    end
  end

  def clean_schema_xml
    d = @xmldoc.dup
    d.xpath('//comment()').remove
    d.css('field').remove
    d.css('fieldType').remove
    d.css('fieldtype').remove
    d.css('dynamicField').remove
    d.css('copyField').remove
    d.css('dynamicfield').remove
    d.css('copyfield').remove
    d.css('schema').children.find_all { |x| x.name == 'text' }.each { |x| x.remove }
    d
  end

  def to_xml
    # Get a clean schema XML document
    d = clean_schema_xml
    s = d.css('schema').first
    [fields, dynamic_fields, copy_fields, field_types].flatten.each do |f|
      s.add_child f.to_xml_node
    end
    d.to_xml
  end


  def write
    File.open(@core.schema_file, 'w:utf-8') do |out|
      out.puts self.to_xml
    end
  end

  def reload
    @core.reload
  end


  # Figuring out which fields are actually produced can be hard:
  #   * If a non-dynamic field name matches, no dynamic_fields will match
  #   * The result of a copyField may match another dynamicField, but the
  #     result of *that* will not match more copyFields
  #   * dynamicFields are matched longest to shortest
  #
  # Suppose I have the following:
  #  dynamic *_ts => string
  #  dynamic *_t  => string
  #  dynamic *_s  => string
  #  dynamic *_ddd => string
  #
  #  copy    *_ts => *_t
  #  copy    *_ts => *_s
  #  copy    *_s  => *_ddd
  #
  # You might expect:
  #  name_ts => string
  #  name_ts copied to name_t => string
  #  name_ts copied to name_s => string
  #  name_s  copied to name_ddd => string
  #
  # ...giving us name_ts, name_t, name_s, and name_ddd
  #
  # What you'll find is that we don't get name_ddd, since
  # name_s was generated by a wildcard-enabled copyField
  # and that's where things stop.
  #
  # However, if you explicitly add a field called
  # name_s, it *will* get copied to name_ddd.
  #
  # Yeah. It's confusing.


  def first_matching_field(str)
    fields.find { |x| x.matches str } or first_matching_dfield(str)
  end

  def first_matching_dfield(str)
    df = dynamic_fields.find { |x| x.matches str }
    if df
      f        = Field.new(df.to_h)
      f[:name] = df.dynamic_name str
    end
    f

  end

  def resulting_fields(str)
    rv = []
    f  = first_matching_field(str)
    rv << f
    copy_fields.each do |cf|
      if cf.matches(f.name)
        dname      = cf.dynamic_name(f.name)
        fmf        = Field.new(first_matching_field(dname).to_h)
        fmf[:name] = dname
        rv << fmf
      end
    end
    rv.uniq
  end

end




