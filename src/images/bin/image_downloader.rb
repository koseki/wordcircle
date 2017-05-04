#! /usr/bin/env ruby

require 'yaml'
require 'json'
require 'uri'
require 'fileutils'
require 'digest/md5'
require 'open-uri'
require 'awesome_print'
require 'nokogiri'
require 'dotenv/load'

STDOUT.sync = true

#
# Generate data/images.yml file
#
class ImageDownloader

  def initialize
    @images_data_file = File.expand_path('../../../../data/images.yml', __FILE__)
    @images_dir = File.expand_path('../../images/', __FILE__)
    @cache_dir = File.expand_path('../../cache/', __FILE__)
    @source_file = File.expand_path('../../images.txt', __FILE__)
  end

  # crab.jpg crab.thumb.jpg crab.1.jpg crab.1.thumb.jpg
  def execute
    data = load_merged_data
    result = {}
    data.each do |word, entries|
      result[word] = []
      entries.each.with_index do |entry, i|
        if entry['ext']
          image_file = File.join(@images_dir, image_file_name(word, i, entry['ext']))
          if File.exist?(image_file)
            result[word] << entry
            next
          end
        end
        new_entry = download_image(word, entry['url'], i)
        new_entry.delete('cache_path')
        result[word] << new_entry
      end
    end

    save_yaml(result)
  end

  def download_image(word, url, index)
    api_result = query_api(url)
    ext = api_result['ext']
    cache_path = api_result['cache_path']
    image_file = File.join(@images_dir, image_file_name(word, index, ext))
    FileUtils.cp(cache_path, image_file)

    return api_result
  end

  def query_api(url)
    if url =~ %r{\Ahttps://pixabay\.com/photo-(\d+)/\z}
      return query_pixabay_api(url, $1)
    elsif url =~ %r{\Ahttp://www\.irasutoya\.com/\d{4}/\d{2}/blog-post_\d+\.html\z}
      return query_irasutoya_api(url)
    elsif url =~ %r{\Ahttps://commons\.wikimedia\.org/wiki/(File:[^&\?/#]+\.(?:jpe?g|png|gif))\z}i
      return query_wikipedia_api(url, $1)
    else
      puts "SKIP: #{url}"
    end
  end

  def query_pixabay_api(url, id)
    cache_url = "https://pixabay.com/api/?id=#{id}&key="
    real_url = cache_url + ENV['PIXABAY_API_KEY']
    cache_path = save_url('pba-', 'json', real_url, cache_url)
    data = JSON.parse(File.read(cache_path))
    data = data['hits'][0]
    image_url = data['webformatURL']
    ext = image_url[/\.([a-zA-Z]{2,4})\z/, 1].downcase
    cache_path = save_url('pbi-', ext, image_url) unless ext.empty?

    return {
      'url' => url,
      'cache_path' => cache_path,
      'site' => 'pixabay',
      'ext' => ext,
      'original' => image_url,
      'api' => cache_url,
      'credit' => {
        'name' => data['user'],
        'id' => data['user_id']
      },
    }
  end

  def query_irasutoya_api(url)
    img_pos = 0
    page_url = url
    if page_url =~ /#(\d+)\z/
      img_pos = $1.to_i
      page_url = page_url.sub(/#(\d+)\z/, '')
    end

    cache_path = save_url('iya-', 'json', page_url)
    doc = Nokogiri::HTML.parse(File.read(cache_path))

    atags = doc.css('.entry').css('a')
    urls = []
    atags.each do |a|
      image_url = a.attr('href')
      image_url = image_url.sub(%r{/s\d+/([^/]+)\z}, '/s640/\1')
      urls << image_url
    end
    image_url = urls[img_pos]
    ext = image_url[/\.([a-zA-Z]{2,4})\z/, 1].downcase
    cache_path = save_url('iyi-', ext, image_url) unless ext.empty?

    return {
      'url' => url,
      'cache_path' => cache_path,
      'site' => 'irasutoya',
      'ext' => ext,
      'original' => image_url,
      'api' => url,
    }
  end

  def query_wikipedia_api(url, title)
    api_url = 'https://commons.wikimedia.org/w/api.php?action=query&format=json'
    api_url += '&prop=imageinfo%7cpageimages&pithumbsize=640&iiprop=extmetadata'
    api_url += '&titles=' + title
    cache_path = save_url('wpa-', 'json', api_url)
    data = JSON.parse(File.read(cache_path))
    data = data['query']['pages'].first[1]
    image_url = data['thumbnail']['source']
    ext = image_url[/\.([a-zA-Z]{2,4})\z/, 1].downcase
    cache_path = save_url('wpi-', ext, image_url) unless ext.empty?

    meta = data['imageinfo'][0]['extmetadata']
    license_name = meta['LicenseShortName']['value'] if meta['LicenseShortName']
    license_url = meta['LicenseUrl']['value'] if meta['LicenseUrl']

    return {
      'url' => url,
      'cache_path' => cache_path,
      'site' => 'wikipedia',
      'ext' => ext,
      'original' => image_url,
      'api' => api_url,
      'license' => {
        'name' => license_name,
        'url' => license_url,
      }
    }
  end

  def save_url(prefix, ext, real_url, cache_url = nil)
    cache_url ||= real_url
    cache_file = prefix + Digest::MD5.hexdigest(cache_url) + '.' + ext
    cache_path = File.join(@cache_dir, cache_file)
    return cache_path if File.exist?(cache_path)

    open(cache_path, 'wb') do |output|
      open(real_url) do |input|
        output.write(input.read)
      end
    end
    puts cache_url + "\t" + cache_file
    sleep 0.25

    cache_path
  end

  def image_file_name(word, index, ext, type = '')
    word = URI.encode_www_form_component(word)
    word = word.gsub(/\./, '%2E')
    name = word
    if index > 0
      name += ".#{index}"
    end
    unless type.empty?
      name += ".#{type}"
    end
    name + '.' + ext
  end

  # merge images.txt and images.yml
  def load_merged_data
    source = load_source_file
    data = load_yaml

    url_data = {}
    data.each do |word, entries|
      entries.each do |entry|
        url_data[entry['url']] = entry
      end
    end

    merged = {}
    source.each do |word, entries|
      merged[word] = []
      entries.each do |entry|
        if url_data[entry['url']]
          entry = url_data[entry['url']]
        end
        merged[word] << entry
      end
    end
    return merged
  end

  def load_source_file
    source = File.read(@source_file)
    data = {}
    word = ''
    source.split(/\n/).each.with_index do |line, i|
      line.strip!
      next if line.empty?
      next if line =~ /\A#/

      if line =~ %r{\Ahttps?://}
        data[word] << { 'url' => line }
      else
        word = line
        data[word] ||= []
      end
    end

    return Hash[data.to_a.select {|a| !a[1].empty? }]
  end

  def load_yaml
    unless File.exist?(@images_data_file)
      return {}
    end
    return YAML.load(File.read(@images_data_file))
  end

  def save_yaml(data)
    File.open(@images_data_file, 'w') do |io|
      io << YAML.dump(data).sub(/\A---\n/, '')
    end
  end
end

ImageDownloader.new.execute