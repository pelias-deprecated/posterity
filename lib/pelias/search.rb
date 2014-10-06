module Pelias

  module Search

    extend self

    FIELD_NAMES = ['name^3', 'admin1_abbr', 'admin0_abbr', 'features'].
      concat(QuattroIndexer::SHAPE_ORDER.flat_map { |f| ["#{f}_name", "#{f}_alternate_names"] })

    def search(term, viewbox = nil, center = nil, size = 10)
      term.downcase!
      query = {
        query: {
          query_string: {
            query: term,
            fields: FIELD_NAMES,
            default_operator: 'AND'
          }
        }
      }
      if viewbox
        viewbox = viewbox.split(',')
        query[:filter] = {
          geo_bounding_box: {
            center_point: {
              top_left: {
                lat: viewbox[1].to_f,
                lon: viewbox[0].to_f
              },
              bottom_right: {
                lat: viewbox[3].to_f,
                lon: viewbox[2].to_f
              }
            }
          }
        }
        unless center
          center_lon = ((viewbox[0].to_f - viewbox[2].to_f) / 2) + viewbox[2].to_f
          center_lat = ((viewbox[1].to_f - viewbox[3].to_f) / 2) + viewbox[3].to_f
          center = "#{center_lon.round(6)},#{center_lat.round(6)}"
        end
      end
      if center
        center = center.split(',')
        query[:sort] = [
          {
            _geo_distance: {
              center_point: [center[0].to_f, center[1].to_f],
              order: 'asc',
              unit: 'km'
            }
          }
        ]
      end
      ES_CLIENT.search(index: Pelias::INDEX, body: query, size: size)
    end

    # Grab suggestions using an ElasticSearch completion suggester:
    # http://www.elasticsearch.org/guide/en/elasticsearch/reference/current/search-suggesters-completion.html
    def suggest(query, size)
      ES_CLIENT.suggest(index: Pelias::INDEX, body: {
        suggestions: {
          text: query,
          completion: {
            field: 'suggest',
            size: size
          }
        }
      })
    end

    def closest(lng, lat, search_type, within_meters = 100)
      ES_CLIENT.search(index: Pelias::INDEX, type: 'location',
        body: {
          query: {
            term: { location_type: search_type }
          },
          filter: {
            geo_distance: {
              distance: "#{within_meters}m",
              center_point: [lng, lat]
            }
          },
          sort: [{
            _geo_distance: {
              center_point: [lng, lat],
              order: 'asc',
              unit: 'm'
            }
          }]
        }
      )
    end

    def encompassing_shapes(lng, lat)
      ES_CLIENT.search(index: Pelias::INDEX, body: {
        query: {
          filtered: {
            query: { match_all: {} },
            filter: {
              geo_shape: {
                boundaries: {
                  shape: {
                    type: 'Point',
                    coordinates: [lng, lat]
                  },
                  relation: 'intersects'
                }
              }
            }
          }
        }
      })
    end

    # Return a single shape, or nil
    def reverse_geocode(lng, lat)
      # try for closest address
      address = closest(lng, lat, 'address')
      return address['hits']['hits'].first if address['hits']['hits'].any?
      # then closest street
      street = closest(lng, lat, 'street')
      return street['hits']['hits'].first if street['hits']['hits'].any?
      # then closest poi
      poi = closest(lng, lat, 'poi')
      return poi['hits']['hits'].first if poi['hits']['hits'].any?
      # otherwise encompassing shapes in order
      shapes = encompassing_shapes(lng, lat)
      unless shapes['hits']['hits'].empty?
        shapes = shapes['hits']['hits']
        %w(neighborhood locality local_admin admin2 admin1 admin0).each do |type|
          shape = shapes.detect { |s| s['_source']['location_type'] == type }
          return shape if shape
        end
      end
      # nothing
      nil
    end

  end

end
