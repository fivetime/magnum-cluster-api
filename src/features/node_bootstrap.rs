use crate::{
    cluster_api::{
        clusterclasses::{
            ClusterClassPatches, ClusterClassPatchesDefinitions,
            ClusterClassPatchesDefinitionsJsonPatches,
            ClusterClassPatchesDefinitionsJsonPatchesValueFrom,
            ClusterClassPatchesDefinitionsSelector,
            ClusterClassPatchesDefinitionsSelectorMatchResources,
            ClusterClassPatchesDefinitionsSelectorMatchResourcesMachineDeploymentClass,
            ClusterClassVariables, ClusterClassVariablesSchema,
        },
        kubeadmconfigtemplates::{
            KubeadmConfigTemplate, KubeadmConfigTemplateTemplateSpecFiles,
        },
        kubeadmcontrolplanetemplates::{
            KubeadmControlPlaneTemplate,
            KubeadmControlPlaneTemplateTemplateSpecKubeadmConfigSpecFiles,
        },
    },
    features::{
        ClusterClassVariablesSchemaExt, ClusterFeatureEntry, ClusterFeaturePatches,
        ClusterFeatureVariables,
    },
};
use base64::prelude::*;
use cluster_feature_derive::ClusterFeatureValues;
use kube::CustomResourceExt;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::json;
use typed_builder::TypedBuilder;

/// The script itself is static; only the versions and the mirror vary, and
/// those arrive in an env file beside it. Keeping the script out of the
/// templated value means a Go-template metacharacter in an operator-supplied
/// mirror URL cannot rewrite the program that runs as root on every node.
const INSTALL_SH: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/data/node-bootstrap/install.sh"
));

const SCRIPT_PATH: &str = "/run/kubeadm/node-bootstrap.sh";
const ENV_PATH: &str = "/run/kubeadm/node-bootstrap.env";

#[derive(Clone, Serialize, Deserialize, JsonSchema, TypedBuilder)]
pub struct NodeBootstrapConfig {
    /// Whether this node has to install Kubernetes at first boot.
    ///
    /// Decided per node group from the Glance record of the image it boots:
    /// an image built by openstack-magnum-images carries `k8s_version` and
    /// needs nothing, a plain distribution image carries none and needs
    /// everything. See `magnum_cluster_api/resources.py`.
    pub enabled: bool,

    /// The Kubernetes version to install, without the leading `v`. This has to
    /// match the version the Machine is created with, or the node joins with a
    /// kubelet the control plane did not expect.
    #[serde(rename = "kubernetesVersion")]
    pub kubernetes_version: String,

    /// Prefix for a mirror of the upstream artifacts, e.g.
    /// `https://artifacts.internal/k8s`. Empty means fetch from upstream.
    /// Checksums are verified either way.
    #[serde(rename = "mirror")]
    pub mirror: String,
}

#[derive(Serialize, Deserialize, ClusterFeatureValues)]
#[allow(dead_code)]
pub struct FeatureValues {
    #[serde(rename = "nodeBootstrap")]
    pub node_bootstrap: NodeBootstrapConfig,
}

pub struct Feature {}

/// The env file the script sources. Rendered by CAPI's Go templating, so the
/// variables are substituted per cluster.
fn env_file_content() -> String {
    // Not base64: this one is templated, and CAPI renders the template before
    // the encoding is applied, so a base64 body would have to be produced by
    // the template itself.
    [
        "# Written by the nodeBootstrap patch. Sourced by node-bootstrap.sh.",
        "K8S_VERSION={{ .nodeBootstrap.kubernetesVersion }}",
        "NODE_BOOTSTRAP_MIRROR={{ .nodeBootstrap.mirror }}",
        "",
    ]
    .join("\n")
}

impl ClusterFeaturePatches for Feature {
    fn patches(&self) -> Vec<ClusterClassPatches> {
        vec![ClusterClassPatches {
            name: "nodeBootstrap".into(),
            // Off unless the image is known to need it. Every way of not
            // knowing lands here, so an image whose record cannot be read is
            // treated exactly as it is treated today.
            enabled_if: Some("{{ if .nodeBootstrap.enabled }}true{{end}}".into()),
            definitions: Some(vec![
                ClusterClassPatchesDefinitions {
                    selector: ClusterClassPatchesDefinitionsSelector {
                        api_version: KubeadmControlPlaneTemplate::api_resource().api_version,
                        kind: KubeadmControlPlaneTemplate::api_resource().kind,
                        match_resources: ClusterClassPatchesDefinitionsSelectorMatchResources {
                            control_plane: Some(true),
                            ..Default::default()
                        },
                    },
                    json_patches: vec![
                        // A literal `value`, not a `valueFrom.template`: the
                        // ClusterClass CRD caps a template at 10240 bytes and
                        // this script is past that once base64-encoded. There
                        // is nothing to render in it anyway - the parts that
                        // vary per cluster go in the env file below.
                        ClusterClassPatchesDefinitionsJsonPatches {
                            op: "add".into(),
                            path: "/spec/template/spec/kubeadmConfigSpec/files/-".into(),
                            value: Some(json!({
                                "path": SCRIPT_PATH,
                                "permissions": "0755",
                                "owner": "root:root",
                                "encoding": "base64",
                                "content": BASE64_STANDARD.encode(INSTALL_SH),
                            })),
                            ..Default::default()
                        },
                        ClusterClassPatchesDefinitionsJsonPatches {
                            op: "add".into(),
                            path: "/spec/template/spec/kubeadmConfigSpec/files/-".into(),
                            value_from: Some(ClusterClassPatchesDefinitionsJsonPatchesValueFrom {
                                template: Some(
                                    serde_yaml::to_string(&KubeadmControlPlaneTemplateTemplateSpecKubeadmConfigSpecFiles {
                                        path: ENV_PATH.to_string(),
                                        permissions: Some("0644".to_string()),
                                        owner: Some("root:root".to_string()),
                                        content: Some(env_file_content()),
                                        ..Default::default()
                                    }).unwrap(),
                                ),
                                ..Default::default()
                            }),
                            ..Default::default()
                        },
                        // Index 0, not "-". The containerdConfig patch appends
                        // "systemctl restart containerd" and carries no
                        // enabledIf, so it applies to this image too - and on
                        // an image with no containerd yet, it fails and takes
                        // the bootstrap down with it. Inserting at the head is
                        // also order-independent: whichever patch CAPI applies
                        // first, this command ends up before that one.
                        ClusterClassPatchesDefinitionsJsonPatches {
                            op: "add".into(),
                            path: "/spec/template/spec/kubeadmConfigSpec/preKubeadmCommands/0".into(),
                            value: Some(json!(format!("bash {SCRIPT_PATH}"))),
                            ..Default::default()
                        },
                    ],
                },
                ClusterClassPatchesDefinitions {
                    selector: ClusterClassPatchesDefinitionsSelector {
                        api_version: KubeadmConfigTemplate::api_resource().api_version,
                        kind: KubeadmConfigTemplate::api_resource().kind,
                        match_resources: ClusterClassPatchesDefinitionsSelectorMatchResources {
                            machine_deployment_class: Some(ClusterClassPatchesDefinitionsSelectorMatchResourcesMachineDeploymentClass {
                                names: Some(vec!["default-worker".to_string()])
                            }),
                            ..Default::default()
                        },
                    },
                    json_patches: vec![
                        // Literal `value`, same 10240-byte reason as above.
                        ClusterClassPatchesDefinitionsJsonPatches {
                            op: "add".into(),
                            path: "/spec/template/spec/files/-".into(),
                            value: Some(json!({
                                "path": SCRIPT_PATH,
                                "permissions": "0755",
                                "owner": "root:root",
                                "encoding": "base64",
                                "content": BASE64_STANDARD.encode(INSTALL_SH),
                            })),
                            ..Default::default()
                        },
                        ClusterClassPatchesDefinitionsJsonPatches {
                            op: "add".into(),
                            path: "/spec/template/spec/files/-".into(),
                            value_from: Some(ClusterClassPatchesDefinitionsJsonPatchesValueFrom {
                                template: Some(
                                    serde_yaml::to_string(&KubeadmConfigTemplateTemplateSpecFiles {
                                        path: ENV_PATH.to_string(),
                                        permissions: Some("0644".to_string()),
                                        owner: Some("root:root".to_string()),
                                        content: Some(env_file_content()),
                                        ..Default::default()
                                    }).unwrap(),
                                ),
                                ..Default::default()
                            }),
                            ..Default::default()
                        },
                        // Head of the list, same reasoning as the control
                        // plane above. The base KubeadmConfigTemplate carries
                        // an empty preKubeadmCommands so that this index
                        // exists whether or not containerdConfig has appended
                        // to it yet.
                        ClusterClassPatchesDefinitionsJsonPatches {
                            op: "add".into(),
                            path: "/spec/template/spec/preKubeadmCommands/0".into(),
                            value: Some(json!(format!("bash {SCRIPT_PATH}"))),
                            ..Default::default()
                        },
                    ],
                },
            ]),
            ..Default::default()
        }]
    }
}

inventory::submit! {
    ClusterFeatureEntry{ feature: &Feature {} }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::features::test::TestClusterResources;
    use crate::resources::fixtures::default_values;
    use pretty_assertions::assert_eq;

    /// Disabled is the default, and disabled has to mean "the ClusterClass
    /// looks exactly as it did before this feature existed" - not "the patch
    /// is applied and the script decides". An image that already carries
    /// Kubernetes must not gain a file or a command.
    #[test]
    fn test_disabled_changes_nothing() {
        let feature = Feature {};

        let mut values = default_values();
        values.node_bootstrap.enabled = false;

        let mut resources = TestClusterResources::new();
        let before = resources
            .kubeadm_control_plane_template
            .spec
            .template
            .spec
            .kubeadm_config_spec
            .clone();

        resources.apply_patches(&feature.patches(), &values);

        assert_eq!(
            resources
                .kubeadm_control_plane_template
                .spec
                .template
                .spec
                .kubeadm_config_spec
                .pre_kubeadm_commands,
            before.pre_kubeadm_commands,
            "a disabled nodeBootstrap must not touch preKubeadmCommands"
        );
        assert_eq!(
            resources
                .kubeadm_control_plane_template
                .spec
                .template
                .spec
                .kubeadm_config_spec
                .files
                .unwrap_or_default()
                .len(),
            before.files.unwrap_or_default().len(),
            "a disabled nodeBootstrap must not add files"
        );
    }

    #[test]
    fn test_control_plane_gets_script_env_and_first_command() {
        let feature = Feature {};

        let mut values = default_values();
        values.node_bootstrap.enabled = true;
        values.node_bootstrap.kubernetes_version = "1.37.0".to_string();
        values.node_bootstrap.mirror = "".to_string();

        let mut resources = TestClusterResources::new();
        resources.apply_patches(&feature.patches(), &values);

        let spec = resources
            .kubeadm_control_plane_template
            .spec
            .template
            .spec
            .kubeadm_config_spec;

        let files = spec.files.expect("files should be set");
        let script = files
            .iter()
            .find(|f| f.path == SCRIPT_PATH)
            .expect("the install script should be written");
        assert_eq!(script.permissions, Some("0755".to_string()));

        let env = files
            .iter()
            .find(|f| f.path == ENV_PATH)
            .expect("the env file should be written");
        let body = env.content.clone().expect("env file should have content");
        assert!(
            body.contains("K8S_VERSION=1.37.0"),
            "the env file should carry the rendered version, got: {body}"
        );

        // The whole point of index 0: this has to precede the containerd
        // restart that containerdConfig appends unconditionally.
        let cmds = spec
            .pre_kubeadm_commands
            .expect("preKubeadmCommands should be set");
        assert_eq!(
            cmds.first(),
            Some(&format!("bash {SCRIPT_PATH}")),
            "the bootstrap must be the first pre-kubeadm command"
        );
    }

    #[test]
    fn test_worker_gets_script_env_and_command() {
        let feature = Feature {};

        let mut values = default_values();
        values.node_bootstrap.enabled = true;
        values.node_bootstrap.kubernetes_version = "1.37.0".to_string();
        values.node_bootstrap.mirror = "https://artifacts.internal/k8s".to_string();

        let mut resources = TestClusterResources::new();
        resources.apply_patches(&feature.patches(), &values);

        let spec = resources
            .kubeadm_config_template
            .spec
            .template
            .spec
            .expect("spec should be set");

        let files = spec.files.expect("files should be set");
        assert!(
            files.iter().any(|f| f.path == SCRIPT_PATH),
            "the worker should get the install script"
        );

        let env = files
            .iter()
            .find(|f| f.path == ENV_PATH)
            .expect("the worker should get the env file");
        let body = env.content.clone().expect("env file should have content");
        assert!(
            body.contains("NODE_BOOTSTRAP_MIRROR=https://artifacts.internal/k8s"),
            "the mirror should reach the node, got: {body}"
        );

        assert_eq!(
            spec.pre_kubeadm_commands,
            Some(vec![format!("bash {SCRIPT_PATH}")]),
            "the worker's bootstrap command should be set"
        );
    }
}
