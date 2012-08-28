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
			  target_directories.each {|d| dirs << File.join(base_directory, d) }
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
	end
end