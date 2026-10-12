.PHONY: install verify test-native e2e web migrate bootstrap dev
install:
	go mod download
	npm ci --ignore-scripts
	npm --prefix web ci
verify:
	npm run verify
web:
	npm --prefix web run build
e2e: web
	node tests/verify.mjs --e2e
test-native:
	@test -n "$$TEST_DATABASE_URL" || (echo 'TEST_DATABASE_URL is required'; exit 1)
	@test -n "$$TEST_API_DATABASE_URL" || (echo 'TEST_API_DATABASE_URL is required'; exit 1)
	@test -n "$$TEST_AUTH_DATABASE_URL" || (echo 'TEST_AUTH_DATABASE_URL is required'; exit 1)
	@test "$$SERK_TEST_ROLE_OVERRIDE" != 1 || (echo 'Native test cannot use test role override'; exit 1)
	go test -race -count=1 -v ./...
migrate:
	go run ./cmd/migrate
bootstrap:
	go run ./cmd/bootstrap --file "$(FILE)"
dev: web
	npm run dev

.PHONY: release-check verify-native upgrade-check
release-check:
	python3 scripts/release-check.py
verify-native:
	python3 scripts/native-check.py
upgrade-check:
	node tests/upgrade.mjs
