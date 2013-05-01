# -*- encoding: utf-8 -*-
require File.expand_path('../lib/ec2launcher/version', __FILE__)

Gem::Specification.new do |gem|
  gem.authors       = ["Sean Laurent"]
  gem.description   = %q{Tool to manage application configurations and launch new EC2 instances based on the configurations.}
  gem.summary       = %q{Tool to launch EC2 instances.}
  gem.homepage      = "https://github.com/StudyBlue/ec2launcher"

  gem.license       = "Apache 2.0"

  gem.files         = `git ls-files`.split($\)
  gem.executables   = gem.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})
  gem.name          = "ec2launcher"
  gem.require_paths = ["lib"]
  gem.version       = EC2Launcher::VERSION

  gem.add_runtime_dependency "aws-sdk", [">= 1.6.6"]
  gem.add_runtime_dependency "log4r"

  gem.add_development_dependency "minitest"
  gem.add_development_dependency "rake"
end
