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
