#SOURCES = $(wildcard java/**/*.java)
rwildcard=$(wildcard $1$2) $(foreach d,$(wildcard $1*),$(call rwildcard,$d/,$2))
SOURCES := $(call rwildcard,java/,*.java)
RELEASE_VERSION = v0.0.14
IMAGES := dockerhub/sunbird-rc-core dockerhub/sunbird-rc-nginx dockerhub/sunbird-rc-context-proxy-service \
			dockerhub/sunbird-rc-public-key-service dockerhub/sunbird-rc-keycloak dockerhub/sunbird-rc-certificate-api \
			dockerhub/sunbird-rc-certificate-signer dockerhub/sunbird-rc-notification-service dockerhub/sunbird-rc-claim-ms \
			dockerhub/sunbird-rc-digilocker-certificate-api dockerhub/sunbird-rc-bulk-issuance dockerhub/sunbird-rc-metrics \
      		dockerhub/sunbird-rc-identity-service dockerhub/sunbird-rc-credential-schema dockerhub/sunbird-rc-credentials-service
      
build: java/registry/target/registry.jar
	echo ${SOURCES}
	rm -rf java/claim/target/*.jar
	cd target && rm -rf * && jar xvf ../java/registry/target/registry.jar && cp ../java/Dockerfile ./ && docker build -t dockerhub/sunbird-rc-core .
	make -C java/claim
	make -C services/certificate-api docker
	make -C services/certificate-signer docker
	make -C services/notification-service docker
	make -C deps/keycloak build
	make -C services/public-key-service docker
	make -C services/context-proxy-service docker
	make -C services/metrics docker
	make -C services/digilocker-certificate-api docker
	make -C services/bulk_issuance docker
	docker build -t dockerhub/sunbird-rc-nginx .
	make -C services/identity-service/ docker
	make -C services/credential-schema docker	
	make -C services/credentials-service/ docker


java/registry/target/registry.jar: $(SOURCES)
	echo $(SOURCES)
	sh configure-dependencies.sh
	cd java && ./mvnw clean install

test: build
	@echo "VIEW_DIR=java/apitest/src/test/resources/views" >> .env || echo "no permission to append to file"
	@echo "SCHEMA_DIR=java/apitest/src/test/resources/schemas" >> .env || echo "no permission to append to file"
	@docker-compose down
	@rm -rf db-data* || echo "no permission to delete"
	# test with distributed definition manager and native search
	@SEARCH_PROVIDER_NAME=dev.sunbirdrc.registry.service.NativeSearchService RELEASE_VERSION=latest KEYCLOAK_IMPORT_DIR=java/apitest/src/test/resources KEYCLOAK_SECRET=a52c5f4a-89fd-40b9-aea2-3f711f14c889 MANAGER_TYPE=DistributedDefinitionsManager DB_DIR=db-data-1 docker-compose up -d db keycloak registry certificate-signer certificate-api redis
	@echo "Starting the test" && sh build/wait_for_port.sh 8080
	@echo "Starting the test" && sh build/wait_for_port.sh 8081
	@docker-compose ps
	@curl -v http://localhost:8081/health
	@cd java/apitest && ../mvnw -Pe2e test || echo 'Tests failed'
	@docker-compose down
	@rm -rf db-data-1 || echo "no permission to delete"
	# test with kafka(async), events, notifications,
	@NOTIFICATION_ENABLED=true NOTIFICATION_URL=http://notification-ms:8765/notification-service/v1/notification TRACK_NOTIFICATIONS=true EVENT_ENABLED=true ASYNC_ENABLED=true RELEASE_VERSION=latest KEYCLOAK_IMPORT_DIR=java/apitest/src/test/resources KEYCLOAK_SECRET=a52c5f4a-89fd-40b9-aea2-3f711f14c889 DB_DIR=db-data-2 docker-compose up -d db es keycloak registry certificate-signer certificate-api kafka zookeeper notification-ms metrics
	@echo "Starting the test" && sh build/wait_for_port.sh 8080
	@echo "Starting the test" && sh build/wait_for_port.sh 8081
	@docker-compose ps
	@curl -v http://localhost:8081/health
	@cd java/apitest && MODE=async ../mvnw -Pe2e test || echo 'Tests failed'
	@docker-compose down
	@rm -rf db-data-2 || echo "no permission to delete"
	# test with fusionauth
	@RELEASE_VERSION=latest DB_DIR=db-data-7 SEARCH_PROVIDER_NAME=dev.sunbirdrc.registry.service.NativeSearchService FUSION_WRAPPER_BUILD=services/sample-fusionauth-service/ FUSIONAUTH_ISSUER_URL=http://fusionauth:9011/ oauth2_resource_uri=http://fusionauth:9011/ oauth2_resource_roles_path=roles identity_provider=dev.sunbirdrc.auth.genericiam.AuthProviderImpl sunbird_sso_url=http://fusionauthwrapper:3990/fusionauth/api/v1/user IMPORTS_DIR=services/sample-fusionauth-service/imports docker-compose -f docker-compose.yml -f services/sample-fusionauth-service/docker-compose.yml up -d db es fusionauth fusionauthwrapper
	sleep 20
	@echo "Starting the test" && sh build/wait_for_port.sh 9011
	@echo "Starting the test" && sh build/wait_for_port.sh 3990
	sleep 20
	@RELEASE_VERSION=latest DB_DIR=db-data-7 SEARCH_PROVIDER_NAME=dev.sunbirdrc.registry.service.NativeSearchService FUSION_WRAPPER_BUILD=services/sample-fusionauth-service/ FUSIONAUTH_ISSUER_URL=http://fusionauth:9011/ oauth2_resource_uri=http://fusionauth:9011/ oauth2_resource_roles_path=roles identity_provider=dev.sunbirdrc.auth.genericiam.AuthProviderImpl sunbird_sso_url=http://fusionauthwrapper:3990/fusionauth/api/v1/user IMPORTS_DIR=services/sample-fusionauth-service/imports docker-compose -f docker-compose.yml -f services/sample-fusionauth-service/docker-compose.yml up -d --no-deps registry
	@echo "Starting the test" && sh build/wait_for_port.sh 8081
	@docker-compose -f docker-compose.yml -f services/sample-fusionauth-service/docker-compose.yml ps
	@curl -v http://localhost:8081/health
	@cd java/apitest && MODE=fusionauth ../mvnw -Pe2e test || echo 'Tests failed'
	@docker-compose -f docker-compose.yml -f services/sample-fusionauth-service/docker-compose.yml down
	@rm -rf db-data-7 || echo "no permission to delete"
	make -C services/certificate-signer test
	make -C services/public-key-service test
	make -C services/context-proxy-service test
	make -C services/bulk_issuance test
	make -C services/identity-service test
	make -C services/credential-schema test
	make -C services/credentials-service test
	
clean:
	@rm -rf target || true
	@rm java/registry/target/registry.jar || true
  
release: test
	for image in $(IMAGES); \
    	do \
    	  echo $$image; \
    	  docker tag $$image:latest $$image:$(RELEASE_VERSION);\
    	  docker push $$image:latest;\
    	  docker push $$image:$(RELEASE_VERSION);\
      	done
	@cd tools/cli/ && npm publish
