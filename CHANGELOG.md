## 1.4.1

* Fixed typo.

## 1.4.0

* When terminating an instance, delete all EBS snapshots for volumes attached to that instance.

## 1.3.12

* Use run_with_backoff when searching for AMI and existing hosts.
* Fixed bug introduced by BlockDeviceBuilder refactoring.

## 1.3.11

* Fixed logging bug in BlockDeviceBuilder (again).

## 1.3.10

* Made additional methods in BlockDeviceBuilder public for reuse elsewhere.
* Fixed small bug in BlockDeviceBuilder when unable to retrieve existing Logger.

## 1.3.9

* More cleanup to terminator code.

## 1.3.8

* Make terminator code more threadsafe.

## 1.3.7

* Added exponential back off to termination process.

## 1.3.6

* Fixed error checking when deleting records from Route53 to be a little less aggressive.

## 1.3.5

* Fixed typo.

## 1.3.4

* Additional error checking when deleting records from Route53.
* More Route53 logging.

## 1.3.3

* Added an extra newline after pre-commands in user-data.

## 1.3.2

* Added support for specifying per-environment IAM profiles in Applications.

## 1.3.1

* Kludge around log4r issue with Route53.

## 1.3.0

* Backward imcompatible change: terminating an instance now requires environment name.
* Added support for automatically adding A records in Route53 for new instances.
* Added support for automatically deleting A records from Route53 when terminating an instance.
* Added new "route53_zone_id" config option to environments to support Route53 integration.

## 1.2.0

* Added support for terminating instances.

## 1.1.3

* Fixed typo with error handling in BackoffRunner.
* Bumped required version of AWS SDK to support IAM Instance Profiles.
* Fixed typo with IAM instance profile attribute name.

## 1.1.2

* Added support for specifying an IAM Instance Profile through the environment and/or application.

## 1.1.1

* Change to calling Bash directly in startup script, instead of running Bash in sh compatibility mode.

## 1.1.0

* Backward imcompatible change. Now defaults to running "ruby", "gem", "chef-client" and "knife" based on the environment.
* Automatically attempts to the load RVM (https://rvm.io/) profile data from /etc/profile.d/rvm.sh.
* Added new "use_rvm" environment and application setting to control loading RVM profile. Defaults to true.

## 1.0.35

* Fixed mistake when launching instances with a specified hostname.

## 1.0.34

* Added missing config loader files.

## 1.0.33

* Refactored config, application and environment loading code to allow easier reuse from other projects.

## 1.0.32

* Copied Alestic's runurl script to avoid problems with LaunchPad is down. Switched to using ec2launcher's copy of runurl.

## 1.0.31

* Added support for pre/post commands to applications. Useful for installing webapps.

## 1.0.30

* Fixed bug with EBS volume mount locations.

## 1.0.28

* Fixed problem with pre/post command inheritance.

## 1.0.27

* Fixed DSL accessor method access.

## 1.0.26

* More exception handling during launch process.

## 1.0.25

* Fixed duplicate commands.

## 1.0.24

* Fixed typos.
* Hide additional logging.

## 1.0.23

* Display subnet CIDR block when launching instances into VPCs.
* Revamped output to use log4r.
* Added command line flags to control output verbosity.

## 1.0.22

* Fixed additional bug with merging applications.

## 1.0.21

* Fixed bugs with merging applications together under certain circumstances.

## 1.0.20

* New command line option to show user-data.
* New command line option to skip the setup scripts.
* Changes to handling RAID array assembly from cloned EBS volumes. Specifically arrays created with mdadm < 3.1.2 that don't use version 1.2 superblocks.
* Fixed typo with cloning/mounting single volumes.
* Cleaned up launch output.

## 1.0.19

* Fixed typo in launch command.

## 1.0.18

* Additional command subsitution variables for ruby, gem, chef-client and knife executables.

## 1.0.17

* Added support to substitute the application name and environment name in pre/post commands.

## 1.0.16

* Added support for custom paths to ruby, gem, chef-client and knife executables.

## 1.0.15

* Fixed problem setting up ephemeral drives.

## 1.0.14

* Added "default" environment for use with security groups.

## 1.0.13

* Fix use of security groups when launching an instance into the public cloud with a security group that is defined with the same name in both the public cloud and a VPC.

## 1.0.12

* Embed runurl and setup.rb scripts in user-data to avoid having to retrieve them.

## 1.0.11

* Support launching multiple instances with one command.

## 1.0.10

* Support multiple "gem" definitions in applications.
* Fixed module reference to InitOptions.
* Move run_with_backoff code into separate module for reusability.

## 1.0.9

* Remove "default" environment.

## 1.0.8

* Create instance with security group ids, instead of security group names. Fixes problem when launching an instance into a VPC with a security group that exists with the same name in the public cloud and in the vpc.
* Automatically find security group ids from names, given a subnet.
* Display private ip adress after launching.
* Overhaul environment inheritance.

## 1.0.7 

* Fixed problem with inheriting from default environment.

## 1.0.6

* Update environment inheritence to merge (instead of replace) gems, packages, roles, commands and security groups.

## 1.0.5

* Fixed bug with resolving environment names when using an environment alias.
