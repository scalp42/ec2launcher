#!/usr/bin/env rake
require "bundler/gem_tasks"
require 'rake/testtask'
Rake::TestTask.new do |t|
  t.libs << 'lib/ec2launcher'
  # t.test_files = FileList['test/ec2launcher/*_test.rb', "test/ec2launcher/dsl/*_test.rb"]
  t.pattern = "test/spec/**/*_spec.rb"
  t.verbose = true
end
task :default => :test