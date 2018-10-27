SHELL := /bin/bash

default: compose

# Make
RD_MAKE_STATE_DIR := .makestate
RUNDECK_IMAGE_DIR := rundeck

# Docker
CONTAINER_PREFIX := $(shell basename $$(pwd))_
NETWORK_NAME := $(CONTAINER_PREFIX)default
NUM_WEB := 2

# Command to call the Rundeck client from outside of the container
RD := tools/rd-0.1.0-SNAPSHOT/bin/rd

# RD env vars
export RD_URL ?= http://127.0.0.1:4440
export RD_BYPASS_URL ?= http://127.0.0.1:4440
export RD_USER ?= admin
export RD_PASSWORD ?= admin
export RD_ENABLE_PLUGINS ?= true

# Plugins
PLUGINS_SRC_DIR := rundeck-plugins
PLUGIN_OUTPUT_DIR := $(RD_MAKE_STATE_DIR)/plugins
PLUGINS = $(shell for p in $$(ls $(PLUGINS_SRC_DIR)); do echo "$(PLUGIN_OUTPUT_DIR)/$${p}.zip"; done)
RD_PLUGIN_STATE = $(shell for p in $$(ls $(PLUGINS_SRC_DIR)); do echo "$(RD_MAKE_STATE_DIR)/$${p}.plugin"; done)

# Rundeck container
RUNDECK_CONTAINER := $(CONTAINER_PREFIX)rundeck_1
RUNDECK_CONTAINER_LIBEXT := /home/rundeck/libext
SSH_AUTHORIZED_KEYS := ssh/authorized_keys

# Makes sure the ssh containers authorize the Rundeck server's public key
$(SSH_AUTHORIZED_KEYS): $(RUNDECK_IMAGE_DIR)/ssh/rundeck-playground.pub
	cp $< $@

# Runs docker-compose to spin up the full environment
compose: $(SSH_AUTHORIZED_KEYS)
	docker-compose up --build

# Installs the plugins into the Rundeck container's plugin directory
plugins: $(RD_MAKE_STATE_DIR)/install-plugins

RD_PLUGIN_INSTALLED_STATE := $(RD_MAKE_STATE_DIR)/install-plugins

$(RD_PLUGIN_INSTALLED_STATE): $(RD_PLUGIN_STATE) $(RD)
	for id in $$($(RD) plugins list | cut -d ' ' -f 1); do \
		$(RD) plugins install --id "$$id"; \
	done && touch $@

$(RD_MAKE_STATE_DIR)/%.plugin: $(PLUGIN_OUTPUT_DIR)/%.zip $(RD)
	NEW_VERSION="$$(unzip -p "$<" | grep ^version | cut -d : -f 2)"; \
	OLD_VERSION="$$(cat "$@" 2>/dev/null || echo '0')"; \
	if [[ $$NEW_VERSION -eq $$OLD_VERSION ]]; then \
		echo "Version already exists for $<"; \
		exit 1; \
	else \
		$(RD) plugins upload -f "$<" &&	echo "$$NEW_VERSION" > $@ && rm -f $(RD_PLUGIN_INSTALLED_STATE); \
	fi

# Creates the Rundeck project and sets its config properties
RD_PROJECT := hello-project
RD_PROJECT_CONFIG_DIR := rundeck-project
RD_PROJECT_STATE := $(RD_MAKE_STATE_DIR)/$(RD_PROJECT)
$(RD_PROJECT_STATE): $(RD_PROJECT_CONFIG_DIR)/project.properties $(RD)
	$(RD) projects create -p $(RD_PROJECT) || true
	$(RD) projects configure update  -p $(RD_PROJECT) --file $< && touch $@

# Installs the Rundeck job configuration
RD_JOBS_ALL := $(RD_MAKE_STATE_DIR)/all.yaml
RD_JOB_FILES = $(shell find $(RD_PROJECT_CONFIG_DIR)/jobs -name '*.yaml' -type f)

$(RD_JOBS_ALL): $(RD_JOB_FILES) $(RD_PROJECT_STATE) $(RD)
	cat $(RD_JOB_FILES) $(RD_PROJECT_STATE) > $@
	$(RD) jobs load -f $@ --format yaml -p $(RD_PROJECT)

# Creates or updates the keys into Key Storage
RD_KEYS_DIR := rundeck-project/key-storage
RD_KEYS_STATES = $(shell cd $(RD_KEYS_DIR) && \
					for f in $$(find . -type f); do \
					   echo $(RD_MAKE_STATE_DIR)$${f/./}.key; \
					done)
$(RD_MAKE_STATE_DIR)/%.key: $(RD_KEYS_DIR)/% $(RD)
	$(RD) keys create -t password -f $< --path $* \
		|| $(RD) keys update -t password -f $< --path $*
	mkdir -p $$(dirname $@) && touch $@

# Installs the secrets into the Rundeck Key Storage
keys: $(RD_KEYS_STATES)

# Tools
PLUGIN_BOOTSTRAP := tools/rundeck-plugin-bootstrap-0.1.0-SNAPSHOT/bin/rundeck-plugin-bootstrap
tools: $(RD) $(PLUGIN_BOOTSTRAP)

$(PLUGIN_BOOTSTRAP):
	docker-compose up --build rundeck-plugin-bootstrap
	docker cp rundeck-playground_rundeck-plugin-bootstrap_1:/root/tools/ .

$(RD):
	docker-compose up --build rundeck-cli
	docker cp rundeck-playground_rundeck-cli_1:/root/tools/ .

env:
	@echo 'export RD_URL="$(RD_URL)";'
	@echo 'export RD_BYPASS_URL="$(RD_BYPASS_URL)";'
	@echo 'export RD_USER="$(RD_USER)";'
	@echo 'export RD_PASSWORD="$(RD_PASSWORD)";'
	@echo 'export RD_ENABLE_PLUGINS="$(RD_ENABLE_PLUGINS)";'
	@echo 'alias rd="$(PWD)/$(RD)";'
	@echo 'alias rundeck-plugin-bootstrap="$(PWD)/$(PLUGIN_BOOTSTRAP)";'

# Installs all the Rundeck config, keys and plugin
rd-config: $(RD_PLUGIN_INSTALLED_STATE) $(RD_JOBS_ALL) $(RD_KEYS_STATES)

# Triggers a Rundeck job
JOB ?= HelloWorld
JOB_OPTIONS ?=
rd-run-job: rd-config $(RD)
	$(RD) run -p $(RD_PROJECT) -f --job '$(JOB)' -- $(JOB_OPTIONS)

# Updates the web.py file in the running containers to simulate a deployment
update-web:
	for i in $(shell seq 1 $(NUM_WEB)); do \
		container=$(CONTAINER_PREFIX)web_$${i}_1; \
		docker cp web/web.py $${container}:/usr/share/web.py; \
	done

# Clears all file and docker state created by this project
clean: clean-makestate clean-plugins clean-docker clean-tools

# Clears the make state files
clean-makestate:
	rm -rf $(RD_MAKE_STATE_DIR)/*

# Clears the zipped plugins
clean-plugins:
	rm -f $(RD_PLUGIN_INSTALLED_STATE) $(RD_PLUGIN_STATE)

# Clears all the docker images, containers, network and volumes
clean-docker:
	docker-compose down --rmi all -v

clean-rundeck:
	docker-compose stop rundeck || true
	docker rm rundeck-playground_rundeck_1 || true
	docker volume rm rundeck-playground_rundeck-data || true
	docker-compose up -d rundeck
	make clean-makestate

clean-tools:
	rm -rf tools/*

# Don't confuse these recipes with files
.PHONY: default compose plugin rd-config rd-run-job update-web keys clean clean-makestate clean-plugins clean-docker clean-rundeck clean-tools tools

# Some make hackery to create a general rule for compiling plugin zips in PLUGINS_SRC_DIR
.SECONDEXPANSION:
$(PLUGIN_OUTPUT_DIR)/%.zip: $$(shell find $(PLUGINS_SRC_DIR)/%/ -type f)
	mkdir -p $$(dirname $@) && cd $(PLUGINS_SRC_DIR) && zip -r ../$@ $*
