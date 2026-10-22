resource "aws_resourcegroups_group" "case1" {
  name        = "case1"
  description = "All resources of the Case 1 infrastructure"

  resource_query {
    query = jsonencode({
      ResourceTypeFilters = ["AWS::AllSupported"]
      TagFilters = [{
        Key    = "Project"
        Values = ["case1"]
      }]
    })
  }
}
