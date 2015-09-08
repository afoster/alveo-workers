module SolrHelper


  # TODO:
  # Maybe refactor this to a multistage process
  # - Map mapped fields
  # - Generate dynamic fields
  #

  def create_solr_document(json_ld_hash)
    (item_graph, document_graphs) = separate_graphs(json_ld_hash)
    mapped_fields = map_fields(item_graph, document_graphs)
    generate_fields = generate_fields(item_graph)
    mapped_fields.merge(generate_fields)
  end

  def separate_graphs(json_ld_hash)
    item_graph = nil
    document_graphs = []
    json_ld_hash.first.each { |graph_hash|
      if is_item? graph_hash
        item_graph = graph_hash
      elsif is_document? graph_hash
        document_graphs << graph_hash
      end
    }
    [item_graph, document_graphs]
  end

  def generate_fields(item_graph)
    generated_fields = generate_access_rights(item_graph)
    generated_fields[date_group_facet: generate_date_group(item_graph)]
    generated_fields[handle: generate_handle(item_graph)]
  end

  def map_fields(item_graph)
    item_fields = map_item_fields(item_graph)
    document_fields = map_document_fields(document_graphs)
    item_fields.merge(document_fields)
  end

  def map_item_fields(item_graph)
    result = get_default_item_fields
    item_graph.each { |key, value|
      if @facet_field_map.has_key? key
        result[facet_field_map[key]] = value
      else
        result.merge(generate_item_fields(key, value))
      end
    }
    result
  end

  def map_document_fields(document_graphs)
    result = get_default_document_fields
    document_graphs.each { |document|
      @document_field_to_rdf_relation_map.each { |key, value|
        result[key] << extract_value(document[value])
      }
    }
    result
  end

  def generate_item_fields(rdf_predicate, value)
    solr_field = map_rdf_predicate_to_solr_field(rdf_predicate)
    solr_value = extract_value(value)
    { "#{solr_field}_ssim" => solr_value, "#{solr_field}_tesim" => solr_value }
  end

  def generate_access_rights(item_graph)
    data_owner = get_data_owner(item_graph)
    collection = get_collection(item_graph)
    if data_owner.nil? or collection.nil?
      raise 'Insufficient metadata to generate access rights'
    end
    build_access_rights_map(data_owner, collection)
  end

  def build_access_rights_map(person, group)
    {
        discover_access_person_ssim: person,
        read_access_person_ssim: person,
        edit_access_person_ssim: person,
        discover_access_group_ssim: "#{group}-discover",
        read_access_group_ssim: "#{group}-read",
        edit_access_group_ssim: "#{group}-edit",
    }
  end

  # TODO change predicate to 'term'
  def map_rdf_predicate_to_solr_field(uri)
    (namespace, term) = get_qualified_term(uri)
    solr_prefix = @rdf_ns_to_solr_prefix_map[namespace]
    solr_prefix + term
  end

  def generate_handle(item_graph)
    collection = get_collection(item_graph)
    identifier = get_identifier(item_graph)
    if collection.nil? || identifier.nil?
      raise 'Insufficient metadata to generate item handle'
    end
    "#{collection}:#{identifier}"
  end

  def extract_value(value)
    result = value
    if value.is_a? Array
      result = value.first.values.first
    end
    normalise_whitespace(result)
  end

  def configure(config)
    @config = config
  end

  ##
  # Sets  the rdf_relation_to_facet_map, which should be a Hash of key-value
  # pairs which map from the JSON-LD relation key to the Solr document
  # facet value. e.g.
  #
  # 'dcterms:isPartOf': collection_name_facet
  #

  def set_rdf_relation_to_facet_map(rdf_relation_to_facet_map)
    @rdf_relation_to_facet_map = rdf_relation_to_facet_map
    @default_item_fields = {}
    rdf_relation_to_facet_map.each_value { |value|
      @default_item_fields[value] = 'unspecified'
    }
  end

  def set_document_field_to_rdf_relation_map(document_field_to_rdf_relation_map)
    @document_field_to_rdf_relation_map = document_field_to_rdf_relation_map
    @default_document_fields = {}
    document_field_to_rdf_relation_map.each_key { |key|
      @default_document_fields[key] = []
    }
  end

  def set_rdf_ns_to_solr_prefix_map(rdf_ns_to_solr_prefix_map)
    @rdf_ns_to_solr_prefix_map = rdf_ns_to_solr_prefix_map
  end

  def generate_date_group(item_graph)
    created_field = extract_value(item_graph[@config['mapped_fields']['created_field']])
    date_group(created_field)
  end


  ##
  # call-seq:
  #   date_group('6 September 1986') => '1980 - 1989'
  #   date_group('6 September 1986', 20) => '1980 - 1999'
  #
  # Takes the year from a `dc:created` string and returns the range
  # that it falls within, as specified by optional resolution parameter

  def date_group(created_field, resolution=10)
    result = 'Unknown'
    begin
      year = extract_year(created_field)
      increment = year / resolution
      range_start = increment * resolution
      range_end = range_start + resolution - 1
      result = "#{range_start} - #{range_end}"
    rescue ArgumentError
    end
    result
  end

  ##
  # call-seq:
  #   extract_year('6 September 1986') => 1986
  #   extract_year('Phase I fall') => 'Unknown'
  #
  # Extracts the year from a dc:created string. Handles the following examples
  #
  # * "1913?"
  # * "30/10/93"
  # * "96/05/17"
  # * "7-11/11/94"
  # * "17&19/8/93"
  # * "2012-03-07"
  # * "August 2000"
  # * "6 September 1986"
  # * "4 Spring 1986"
  # * "Phase I fall"

  def extract_year(created_field)
    created_field.chomp!('?')
    date_array = created_field.split(/[\-\/\&\s]/)
    begin
      candidate = Integer date_array.first
      if candidate > 31
        year = candidate
      else
        year = Integer date_array.last
      end
    rescue ArgumentError
      year = Integer date_array.last
    end
    year = year + 1900 if year < 100
    year
  end

  def graph_type(graph_hash)
    get_unqualified_term(graph_hash['@type'].first)
  end

  def get_qualified_term(uri)
    term = get_unqualified_term(uri)
    namespace = uri[0..-(term.length+1)]
    [namespace, term]
  end

  def get_unqualified_term(uri)
    uri.split('/').last
  end

  def normalise_whitespace(value_string)
    result = value_string
    if result.is_a? String
      result = result.gsub(/\s+/, ' ').strip
    end
    result
  end

  def get_identifier(item_graph)
    identifier = extract_value(item_graph[@config['mapped_fields']['identifier_field']])
    get_unqualified_term(identifier)
  end

  def get_collection(item_graph)
    collection_uri = extract_value(item_graph[@config['mapped_fields']['collection_field']])
    get_unqualified_term(collection_uri)
  end

  def get_data_owner(item_graph)
    data_owner = @config['mapped_fields']['default_data_owner']
    data_owner_field = @config['mapped_fields']['data_owner_field']
    if item_graph[data_owner_field]
      data_owner = extract_value(item_graph[data_owner_field])
    end
    data_owner
  end

  def get_default_item_fields
    @default_item_fields.clone
  end

  def get_default_document_fields
    @default_document_fields.clone
  end

  def is_document?(graph_hash)
    graph_type(graph_hash) == 'Document'
  end

  def is_item?(graph_hash)
    graph_type(graph_hash) == 'AusNCObject'
  end

end
