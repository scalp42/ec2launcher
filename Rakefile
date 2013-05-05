#!/usr/bin/env rake
require "bundler/gem_tasks"
require 'rake/testtask'

Rake::TestTask.new do |t|
  t.name = "testspec"
  t.libs << 'lib/ec2launcher'
  t.pattern = "test/spec/**/*_spec.rb"
  t.verbose = true
end

Rake::TestTask.new do |t|
  t.libs << 'lib/ec2launcher'
  t.pattern = "test/unit/**/*_test.rb"
  t.verbose = true
end

task :default => :test