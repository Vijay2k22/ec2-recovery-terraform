variable "alert_email" {
  description = "Email address to receive recovery notifications; confirm the SNS subscription email."
  type        = string
  validation {
    condition     = can(regex("^[^@ ]+@[^@ ]+\\.[^@ ]+$", var.alert_email))
    error_message = "Provide a valid email address."
  }
}
variable "ssh_cidr" {
  description = "Your public IP as a /32 CIDR for SSH to the Hyderabad monitor."
  type        = string
  validation {
    condition     = can(cidrhost(var.ssh_cidr, 0)) && endswith(var.ssh_cidr, "/32")
    error_message = "Use your public IPv4 address with /32, for example 203.0.113.10/32."
  }
}
variable "key_name_hyd" {
  description = "Existing EC2 key pair name in ap-south-2. Leave empty to use EC2 Instance Connect if available."
  type        = string
  default     = null
}
variable "web_instance_type" {
  type    = string
  default = "t3.micro"
}
variable "monitor_instance_type" {
  type    = string
  default = "t3.micro"
}
variable "prefix" {
  type    = string
  default = "recovery-lab"
}
