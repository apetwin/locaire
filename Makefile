.PHONY: help run down push tools tofu apply

help: ## list all targets with one-line descriptions
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

run: ## call scripts/setup.sh
	@bash scripts/setup.sh

down: ## destroy the cluster
	@cd bootstrap && tofu destroy -auto-approve

push: ## bump patch tag and push (bumps minor if patch >= 9)
	@LATEST=$$(git tag -l 'v*' --sort=-v:refname | head -n1); \
	LATEST=$${LATEST:-v0.0.0}; \
	VERSION=$${LATEST#v}; \
	MAJOR=$$(echo $$VERSION | cut -d. -f1); \
	MINOR=$$(echo $$VERSION | cut -d. -f2); \
	PATCH=$$(echo $$VERSION | cut -d. -f3); \
	if [ "$$PATCH" -ge 9 ]; then \
		MINOR=$$((MINOR + 1)); \
		PATCH=0; \
	else \
		PATCH=$$((PATCH + 1)); \
	fi; \
	TAG="v$${MAJOR}.$${MINOR}.$${PATCH}"; \
	echo "Tagging $$TAG"; \
	git tag "$$TAG"; \
	git push origin "$$TAG"

tools: ## install opentofu, k9s, flux CLI
	@curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o /tmp/install-opentofu.sh && \
		chmod +x /tmp/install-opentofu.sh && \
		/tmp/install-opentofu.sh --install-method standalone && \
		rm -f /tmp/install-opentofu.sh
	@curl -sS https://webi.sh/k9s | sh
	@curl -s https://fluxcd.io/install.sh | bash

tofu: ## initialize OpenTofu in bootstrap/
	@cd bootstrap && tofu init

apply: ## apply OpenTofu config
	@cd bootstrap && tofu apply -auto-approve
