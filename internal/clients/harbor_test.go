package clients

import (
	"encoding/json"
	"testing"

	"github.com/google/go-cmp/cmp"

	"github.com/crossplane/upjet/v2/pkg/terraform"
)

func TestTerraformProviderConfigurationBuilder(t *testing.T) {
	tests := map[string]struct {
		credentials string
		want        terraform.ProviderConfiguration
	}{
		"OmittedCredentials": {
			credentials: `{}`,
			want:        terraform.ProviderConfiguration{},
		},
		"ExistingCredentials": {
			credentials: `{
				"url": "https://harbor.example.com",
				"username": "admin",
				"password": "test-password",
				"robot_prefix": "robot$",
				"api_version": 2,
				"bearer_token": "test-token",
				"session_id": "test-session",
				"insecure": false
			}`,
			want: terraform.ProviderConfiguration{
				"url":          "https://harbor.example.com",
				"username":     "admin",
				"password":     "test-password",
				"robot_prefix": "robot$",
				"api_version":  2,
				"bearer_token": "test-token",
				"session_id":   "test-session",
				"insecure":     false,
			},
		},
		"CustomHeaders": {
			credentials: `{
				"url": "https://harbor.example.com",
				"bearer_token": "test-token",
				"headers": {
					"X-Proxy-Token": "test-proxy-token",
					"Host": "harbor.internal"
				}
			}`,
			want: terraform.ProviderConfiguration{
				"url":          "https://harbor.example.com",
				"bearer_token": "test-token",
				"headers": map[string]string{
					"X-Proxy-Token": "test-proxy-token",
					"Host":          "harbor.internal",
				},
			},
		},
		"EmptyHeaders": {
			credentials: `{"headers": {}}`,
			want: terraform.ProviderConfiguration{
				"headers": map[string]string{},
			},
		},
		"NullHeaders": {
			credentials: `{"headers": null}`,
			want:        terraform.ProviderConfiguration{},
		},
	}
	for name, tt := range tests {
		t.Run(name, func(t *testing.T) {
			var credentials harborConfig
			if err := json.Unmarshal([]byte(tt.credentials), &credentials); err != nil {
				t.Fatal(err)
			}
			got := terraformProviderConfigurationBuilder(credentials)
			if diff := cmp.Diff(tt.want, got); diff != "" {
				t.Errorf("provider configuration mismatch (-want +got):\n%s", diff)
			}
		})
	}
}
