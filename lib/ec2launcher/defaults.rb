#
# Copyright (c) 2012 Sean Laurent
#
module EC2Launcher
  DEFAULT_VOLUME_SIZE = 60 # in GB

  AVAILABILITY_ZONES = %w{us-east-1a us-east-1b us-east-1c us-east-1d}
  INSTANCE_TYPES = %w{m1.small m1.medium m1.large m1.xlarge t1.micro m2.xlarge m2.2xlarge m2.4xlarge c1.medium c1.xlarge cc1.4xlarge cg1.4xlarge}

  RUN_URL_SCRIPT = "https://raw.github.com/StudyBlue/ec2launcher/master/startup-scripts/runurl"
  SETUP_SCRIPT = "https://raw.github.com/StudyBlue/ec2launcher/master/startup-scripts/setup.rb"
end