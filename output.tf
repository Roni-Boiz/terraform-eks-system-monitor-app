output "endpoint" {
  value = aws_eks_cluster.system-monitor-cluster.endpoint
}

output "elb_dns_name" {
  value = null_resource.get_elb_dns.*.output
}