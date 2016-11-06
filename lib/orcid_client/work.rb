# load ENV variables from .env file if it exists
env_file = File.expand_path("../../../.env", __FILE__)
if File.exist?(env_file)
  require 'dotenv'
  Dotenv.load! env_file
end

# load ENV variables from container environment if json file exists
# see https://github.com/phusion/baseimage-docker#envvar_dumps
env_json_file = "/etc/container_environment.json"
if File.exist?(env_json_file)
  env_vars = JSON.parse(File.read(env_json_file))
  env_vars.each { |k, v| ENV[k] = v }
end

# default values for some ENV variables
ENV['ORCID_API_URL'] ||= "https://api.sandbox.orcid.org"

require 'active_support/all'
require 'nokogiri'
require 'bibtex'

require_relative 'metadata'
require_relative 'author'
require_relative 'date'
require_relative 'work_type'
require_relative 'api'

module OrcidClient
  class Work
    include OrcidClient::Metadata
    include OrcidClient::Author
    include OrcidClient::Date
    include OrcidClient::WorkType
    include OrcidClient::Api

    attr_reader :doi, :orcid, :schema, :access_token, :validation_errors

    def initialize(doi:, orcid:, access_token:, **options)
      @doi = doi
      @orcid = orcid
      @access_token = access_token
    end

    SCHEMA = File.expand_path("../../../resources/record_#{API_VERSION}/work-#{API_VERSION}.xsd", __FILE__)

    def metadata
      @metadata ||= get_metadata(doi, 'datacite')
    end

    def contributors
      Array(metadata.fetch('author', nil)).map do |contributor|
        { orcid: contributor.fetch('ORCID', nil),
          credit_name: get_credit_name(contributor),
          role: nil }.compact
      end
    end

    def author_string
      Array(metadata.fetch('author', nil)).map do |contributor|
        get_full_name(contributor)
      end.join(" and ")
    end

    def title
      metadata.fetch('title', nil)
    end

    def container_title
      metadata.fetch('container-title', nil)
    end

    def publisher_id
      metadata.fetch('publisher_id', nil)
    end

    def publication_date
      get_year_month_day(metadata.fetch('published', nil))
    end

    def description
      Array(metadata.fetch('description', nil)).first
    end

    def type
      orcid_work_type(metadata.fetch('type', nil), metadata.fetch('subtype', nil))
    end

    def has_required_elements?
      doi && contributors && title && container_title && publication_date
    end

    def citation
      return nil unless has_required_elements?

      url = "https://doi.org/#{doi}"

      # generate citation in bibtex format. Use the url as bibtex key.
      BibTeX::Entry.new({
        bibtex_type: :data,
        bibtex_key: url,
        author: author_string,
        title: title,
        publisher: container_title,
        doi: doi,
        url: url,
        year: publication_date['year']
      }).to_s.gsub("\n",'').gsub(/\s+/, ' ')
    end

    def data
      return nil unless has_required_elements?

      Nokogiri::XML::Builder.new(:encoding => 'UTF-8') do |xml|
        xml.send(:'work:work', root_attributes) do
          insert_work(xml)
        end
      end.to_xml
    end

    def insert_work(xml)
      insert_titles(xml)
      insert_description(xml)
      insert_citation(xml)
      insert_type(xml)
      insert_pub_date(xml)
      insert_ids(xml)
      insert_contributors(xml)
    end

    def insert_titles(xml)
      if title
        xml.send(:'work:title') do
          xml.send(:'common:title', title)
        end
      end

      xml.send(:'work:journal-title', container_title) if container_title
    end

    def insert_description(xml)
      return nil unless description.present?

      xml.send(:'work:short-description', description.truncate(2500, separator: ' '))
    end

    def insert_citation(xml)
      return nil unless citation.present?

      xml.send(:'work:citation') do
        xml.send(:'work:citation-type', 'bibtex')
        xml.send(:'work:citation-value', citation)
      end
    end

    def insert_type(xml)
      xml.send(:'work:type', type)
    end

    def insert_pub_date(xml)
      if publication_date['year']
        xml.send(:'common:publication-date') do
          xml.year(publication_date.fetch('year'))
          xml.month(publication_date.fetch('month', nil)) if publication_date['month']
          xml.day(publication_date.fetch('day', nil)) if publication_date['month'] && publication_date['day']
        end
      end
    end

    def insert_ids(xml)
      xml.send(:'common:external-ids') do
        insert_id(xml, 'doi', doi)
      end
    end

    def insert_id(xml, id_type, value)
      xml.send(:'common:external-id') do
        xml.send(:'common:external-id-type', id_type)
        xml.send(:'common:external-id-value', value)
      end
    end

    def insert_contributors(xml)
      return nil unless contributors.present?

      xml.send(:'work:contributors') do
        contributors.each do |contributor|
          xml.contributor do
            insert_contributor(xml, contributor)
          end
        end
      end
    end

    def insert_contributor(xml, contributor)
      if contributor[:orcid].present?
        xml.send(:'common:contributor-orcid') do
          xml.send(:'common:uri', contributor[:orcid])
          xml.send(:'common:path', contributor[:orcid][17..-1])
          xml.send(:'common:host', 'orcid.org')
        end
      end
      xml.send(:'credit-name', contributor[:credit_name])
      if contributor[:role]
        xml.send(:'contributor-attributes') do
          xml.send(:'contributor-role', contributor[:role])
        end
      end
    end

    def without_control(s)
      r = ''
      s.each_codepoint do |c|
        if c >= 32
          r << c
        end
      end
      r
    end

    def root_attributes
      { :'xmlns:xsi' => 'http://www.w3.org/2001/XMLSchema-instance',
        :'xsi:schemaLocation' => 'http://www.orcid.org/ns/work ../work-2.0_rc3.xsd',
        :'xmlns:common' => 'http://www.orcid.org/ns/common',
        :'xmlns:work' => 'http://www.orcid.org/ns/work' }
    end

    def schema
      Nokogiri::XML::Schema(open(SCHEMA))
    end

    def validation_errors
      @validation_errors ||= schema.validate(Nokogiri::XML(data)).map { |error| error.to_s }
    end
  end
end