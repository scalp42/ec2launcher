#
# Copyright (c) 2012 Sean Laurent
#
require 'rubygems'
require 'log4r'

include Log4r

module EC2Launcher
	module DirectoryProcessing
		# Attempts to build a list of valid directories.
		#
		# @param [Array<String>, nil] target_directories list of possible directories
		# @param [String] default_directory directory to use if the target_directories list is empty or nil
		# @param [String] name name of the type of directory. Used only for error messages.
		# @param [Boolean] fail_on_error exit with an error if the list of valid directories is empty
		#
		# @return [Array<String] list of directories that exist
		#
		def process_directory_list(base_directory, target_directories, default_directory, name, fail_on_error = false)
			log = Logger['ec2launcher']
			dirs = []
			if target_directories.nil?
			  dirs << File.join(base_directory, default_directory)
			else
			  target_directories.each do |d| 
			  	dirs << File.join(base_directory, d)
			  end
			end
			valid_directories = build_list_of_valid_directories(dirs)

			if valid_directories.empty?
			  temp_dirs = dirs.each {|d| "'#{d}'"}.join(", ")
			  if fail_on_error
			    abort("ERROR - #{name} directories not found: #{temp_dirs}")
			  else
			    log.warn "WARNING - #{name} directories not found: #{temp_dirs}"
			  end
			end

			valid_directories
		end

		private

    # Given a list of possible directories, build a list of directories that actually exist.
    #
    # @param [Array<String>] directories list of possible directories
    # @return [Array<String>] directories that exist or an empty array if none of the directories exist.
    #
    def build_list_of_valid_directories(directories)
      dirs = []
      unless directories.nil?
        if directories.kind_of? Array
          directories.each {|d| dirs << d if File.directory?(d) }
        else
          dirs << directories if File.directory?(directories)
        end
      end
      dirs
    end
	end
end