output "public_addr__symbolapi__http" {
    value = "${aws_elb.elb_for_symbolapi.dns_name}"
}