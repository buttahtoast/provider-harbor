package membergroup

import "github.com/crossplane/upjet/v2/pkg/config"

// Configure harbor_project_member_group resource
func Configure(p *config.Provider) {
	p.AddResourceConfigurator("harbor_project_member_group", func(r *config.Resource) {
		r.ShortGroup = "project"
		r.Kind = "MemberGroup"
		// Upjet strips text before the first dash in argument docs.
		r.MetaResource.ArgumentDocs["group_name"] = "- " + r.MetaResource.ArgumentDocs["group_name"]
		r.References["project_id"] = config.Reference{
			TerraformName: "harbor_project",
		}
	})
}
