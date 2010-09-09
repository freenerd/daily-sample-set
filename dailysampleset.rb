#!/usr/bin/env ruby

require 'setup'
# setup.rb should have 
# ECHONEST_API_KEY
# SC_CONSUMER_KEY
# SC_CONSUMER_SECRET
# SC_ACCESS_TOKEN
# SC_ACCESS_TOKEN_SECRET

require 'echonest'
gem 'soundcloud-ruby-api-wrapper'
require 'soundcloud'

gem 'oauth'
require 'oauth'

DIRECTORY_ORIGINALS = 'originals'
DIRECTORY_SAMPLES = 'samples'
SOX_TRIM_BLEED = 0.1 # More time at beginning and end of sample cutting
DURATION = 100000 # in milliseconds

class HotSampleSet
  
  def self.get_tracks_from_soundcloud(offset)
    tracks = []
    sc_client = Soundcloud.register({:consumer_key => SC_CONSUMER_KEY, :consumer_secret => SC_CONSUMER_SECRET})
    hot_tracks = sc_client.Track.find(:all,:params => {"created_at[to]" => Time.now,
                                                       "created_at[from]" => Time.now - 1.day, 
                                                       :order_by => 'hotness', 
                                                       :limit => 50, 
                                                       :offset => offset, 
                                                       :license => 'some-or-no-rights-reserved',
                                                       :filter => 'downloadable,streamable,public'})
    hot_tracks.each {|track|
      print '|'
      if track.downloadable
        if track.duration < DURATION
          # we only want uncompressed files
          if ['wav', 'aiff', 'aif', 'flac'].include? track.original_format.to_s
            p '#'                      
            trackname = track.permalink.to_s + '.' + track.original_format.to_s
            wget_call = "wget -O '#{DIRECTORY_ORIGINALS}/#{trackname}' #{track.download_url}"
            wget = IO.popen(wget_call)
            wget_output = wget.readlines
            puts wget_output.join
            p "file #{trackname} written"
            tracks << track
            break # uncomment if you only want one track for debugging
          end
        end  
      end
    }
    puts ''
    puts "finished fetching tracks from soundcloud with offset #{offset}"
    tracks
  end

  # send a song to echonest for analysis
  def self.analyze_with_echonest(track)
    echonest = Echonest(ECHONEST_API_KEY)
    md5 = echonest.request(:upload, :url => track.stream_url)
    # echonest api is unrelyable, we don't know when queue is done
    tries = 0
    begin
      bars = echonest.send("get_bars", md5)
    rescue Echonest::Api::Error
      sleep 1
      tries += 1
      if tries < 20
        puts 'Waiting for Echonest to process track ...'
        retry 
      else
        puts 'Something is wrong with echonest analysis. Screw this!'
        exit
      end
    end      
    
    chunks = []
    (0..bars.length-2).each {|i|
      length = i + 4
      if length > bars.length-2 then length = bars.length-2 end
      chunks[i] = {:start => bars[i].value, :length => bars[length].value - bars[i].value}
    }
    chunks
  end  
  
  def self.execute_sox(arguments)
    sox_call = "sox -V2 #{arguments}"
    sox = IO.popen(sox_call)
    sox_output = sox.readlines
    puts sox_output.join    
  end  
  
end
  
  
# The actual program if called from command line
if __FILE__ == $0
  
  banner = '
  .__     .      __.           .      __.    , 
  |  \ _.*|  .  (__  _.._ _ ._ | _   (__  _ -+-
  |__/(_]||\_|  .__)(_][ | )[_)|(/,  .__)(/, | 
           ._|              |
  '
  puts banner
  puts ''
  puts 'Fetching the latest public downloadable uncompressed files from SoundCloud'
  puts ''
  
  # clean directories
  if ARGV.length == 0 || (ARGV.length == 1 && ARGV[0] != '--noclean')    
    [DIRECTORY_ORIGINALS, DIRECTORY_SAMPLES].each {|directory|
      dir = Dir.new('./' + directory + '/').entries
      if dir.length > 2 #there is always '.' and '..' in it
        puts "cleaning #{directory}:"
        dir.each {|file|
          if file[0] != '.'
             File.delete('./' + directory + '/' + file)
             print " #{file}"
          end
        }
        puts ''
      end
    }
    puts ''
  end

  # fetch from SoundCloud
  tracks = []
  offset = 0
  while tracks.empty?
    tracks = HotSampleSet.get_tracks_from_soundcloud(offset)
    offset += 50
  end

  # analyze tracks with echonest and split
  all_chunks = []
  tracks.each {|track|
    original_filename = './' + DIRECTORY_ORIGINALS + '/' + track.permalink.to_s + '.' + track.original_format.to_s
    sample_filename = './' + DIRECTORY_SAMPLES + '/' + track.permalink.to_s + '.' + track.original_format.to_s
  
    puts "#{track.permalink}: sending to echonest"
    chunks = HotSampleSet.analyze_with_echonest(track)
        
    puts "#{track.permalink}: fetched info -> splitting file"
    (1..3).each {|i|
      # randomly get a chunk
      chunk = chunks[rand(chunks.length)]
      arguments = "#{original_filename} #{sample_filename}#{i}.wav trim #{chunk[:start] - SOX_TRIM_BLEED} #{chunk[:length] + SOX_TRIM_BLEED}"
      HotSampleSet.execute_sox(arguments)
      puts "#{track.permalink}: split #{sample_filename}#{i}.wav"
      all_chunks << "#{sample_filename}#{i}.wav"
    }
  }

  # Upload to SoundCloud
  puts "Let's upload the Samples to SoundCloud"
  sc_consumer = Soundcloud.consumer(SC_CONSUMER_KEY, SC_CONSUMER_SECRET)
  access_token = OAuth::AccessToken.new(sc_consumer, SC_ACCESS_TOKEN, SC_ACCESS_TOKEN_SECRET)
  sc_client = Soundcloud.register({:access_token => access_token})
  my_user = sc_client.User.find_me
  
  sample_number = all_chunks.length
  day = Time.now.strftime("%A %B %d %Y")
  all_chunks.each {|chunk|
    track = sc_client.Track.create(
      :title      => "Sample #{sample_number} from #{day}",
      :asset_data => File.open("#{chunk}"),
      :downloadable => true,
      :streamable => true,
      :sharing => 'public',
      :track_type => 'sample'
    )
    puts "Uploaded Sample Number #{sample_number} to SoundCloud "    
    sample_number -= 1
  }
   
  puts ''
  puts 'We are done here for today.'
  puts 'Have a nice (hack) day.'   
  
  # Saving to playlist somehow doesn't work ...
  # playlist = sc_client.Playlist.create(
  #   :title      => "Test Test"
  # )
    
  #  query = "/playlist/#{playlist.attributes['id']}/tracks/#{track.attributes['id']}"
  #  p query
  #  p access_token.put(query)
  #   
end