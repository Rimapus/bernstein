// Build definition for the application images, driven by the Makefile at the
// repository root (`make images` -> docker buildx bake --push).
// Contexts are relative to this directory.

variable "REGISTRY" {
  default = "10.10.80.40:5000"
}

variable "TAG" {
  default = "dev"
}

group "default" {
  targets = ["poll", "worker", "result"]
}

target "poll" {
  context = "poll"
  tags    = ["${REGISTRY}/poll:${TAG}"]
}

target "worker" {
  context = "worker"
  tags    = ["${REGISTRY}/worker:${TAG}"]
}

target "result" {
  context = "result"
  tags    = ["${REGISTRY}/result:${TAG}"]
}
