# "recommended" is already the default preset of the ruleset bundled with TFLint, so this
# block only makes it explicit. No source or version: the bundled plugin needs no install.
# https://github.com/terraform-linters/tflint-ruleset-terraform/blob/main/docs/configuration.md
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
