.PHONY: help setup run-backend run-flutter docker-up docker-down clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

setup: ## Initial project setup
	cd backend && go mod tidy
	cd .. && flutter pub get

run-backend: ## Run Go backend locally
	cd backend && go run ./cmd/server

run-flutter: ## Run Flutter app (Chrome)
	cd .. && flutter run -d chrome

run-android: ## Run Flutter app (Android)
	cd .. && flutter run -d android

run-ios: ## Run Flutter app (iOS)
	cd .. && flutter run -d ios

run-macos: ## Run Flutter app (macOS)
	cd .. && flutter run -d macos

docker-up: ## Start Docker containers (PostgreSQL, Redis)
	docker-compose up -d

docker-down: ## Stop Docker containers
	docker-compose down

docker-logs: ## View Docker logs
	docker-compose logs -f

clean: ## Clean build artifacts
	cd backend && rm -rf server
	cd .. && flutter clean

db-connect: ## Connect to PostgreSQL
	docker exec -it edclass-db-1 psql -U postgres -d edclass
