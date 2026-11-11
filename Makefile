.PHONY: fmt validate test docs

fmt:
	terraform fmt -recursive

validate:
	terraform validate

test: validate
	terraform test

docs:
	terraform-docs .
