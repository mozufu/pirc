{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    concatStringsSep
    literalExpression
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    mkRemovedOptionModule
    mkRenamedOptionModule
    optional
    types
    ;

  cfg = config.services.pirc;
  json = builtins.toJSON;
  csv = concatStringsSep ",";

  workspaceType = types.submodule (
    { name, ... }: {
      options = {
        id = mkOption {
          type = types.str;
          default = name;
          description = "Stable workspace identifier.";
        };
        path = mkOption {
          type = types.str;
          description = "Absolute workspace path visible to the pirc service account.";
        };
        displayName = mkOption {
          type = types.str;
          default = name;
          description = "Workspace name shown in the web client.";
        };
        defaults = mkOption {
          type = types.attrsOf types.anything;
          default = { };
          description = "Default model/thinking settings passed to the gateway.";
        };
      };
    }
  );

  workspaceList = lib.mapAttrsToList (_: workspace: {
    inherit (workspace)
      id
      path
      displayName
      defaults
      ;
  }) cfg.workspaces;

  # The gateway only routes; the local chat/node binary runs agents and
  # shells. They share a token generated on first start, never in the store.
  # The gateway runs as its own account, so nothing the node runs (agents,
  # their shells, side-panel terminals) can read the gateway's state: its
  # keys, OAuth logins, push keys and this token. The node gets the token as
  # a systemd credential.
  gatewayUser = cfg.gatewayUser;
  daemonState = "${cfg.stateDirectory}/daemon";
  nodeState = "${cfg.stateDirectory}/node";
  tokenFile = "${daemonState}/local-node-token";
  legacyTokenFile = "${cfg.stateDirectory}/local-node-token";

  # The gateway accepts forward-auth identities only from trusted proxy
  # addresses. On one host that is 127.0.0.1, which every local process
  # (agents included) can also connect from, so nginx additionally proves
  # itself with a shared secret (PIRC_PROXY_SECRET / x-pirc-proxy-secret).
  # Generated at runtime, never in the store: the gateway reads it from its
  # state directory; nginx includes a header snippet from a directory only
  # root and the nginx group can read.
  useProxySecret = cfg.nginx.enable && cfg.nginx.proxySecret;
  proxySecretFile = "${daemonState}/proxy-secret";
  proxySecretDir = "/run/pirc-nginx";
  nginxGroup = config.services.nginx.group;

  gatewayEnvironment = {
    PIRC_HOST = cfg.listenAddress;
    PIRC_PORT = toString cfg.port;
    PIRC_STATE_DIR = daemonState;
    PIRC_TRUSTED_PROXIES = csv cfg.trustedProxies;
    PIRC_IDENTITY_HEADER = cfg.identityHeader;
    PIRC_ALLOWED_USERS = csv cfg.allowedUsers;
    PIRC_ALLOWED_ORIGINS = csv cfg.allowedOrigins;
    PIRC_ALLOWED_HOSTS = csv cfg.allowedHosts;
    PIRC_MODELS_FILE = "/etc/pirc/models.json";
  }
  // lib.optionalAttrs (cfg.timeZone != null) {
    PIRC_TIMEZONE = cfg.timeZone;
  }
  # Turning the generated nginx secret off is an explicit opt-out. Without the
  # generated nginx, the operator's own proxy must send a secret supplied through
  # the environment file.
  // lib.optionalAttrs (cfg.nginx.enable && !cfg.nginx.proxySecret) {
    PIRC_PROXY_SECRET_REQUIRED = "false";
  }
  // cfg.environment;

  nodeEnvironment = {
    PIRC_NODE_ID = cfg.localNode.id;
    PIRC_DAEMON_URL = "ws://127.0.0.1:${toString cfg.port}";
    PIRC_STATE_DIR = nodeState;
    PIRC_ALLOWED_USERS = csv cfg.allowedUsers;
    PIRC_WORKSPACES = json workspaceList;
    PIRC_CONFIG_DIR = "${agentConfigDir}";
    PIRC_TERMINALS = lib.boolToString cfg.terminals;
    PIRC_BROWSER = lib.boolToString cfg.browser.enable;
    # The agents' browser must not reach the gateway under its public names either.
    PIRC_BROWSER_BLOCK_HOSTS = csv (map (h: lib.head (lib.splitString ":" h)) cfg.allowedHosts);
  }
  // lib.optionalAttrs cfg.browser.enable {
    PIRC_BROWSER_EXECUTABLE = lib.getExe cfg.browser.package;
    PIRC_FFMPEG = lib.getExe' cfg.browser.ffmpeg "ffmpeg";
  }
  // cfg.environment;

  # Runs as root (the "+" in ExecStartPre): creates the token, or moves one
  # from where older versions kept it, readable by the gateway alone.
  ensureToken = pkgs.writeShellScript "pirc-local-node-token" ''
    set -eu
    PATH=${lib.makeBinPath [ pkgs.coreutils ]}
    install -d -m 0700 -o ${gatewayUser} -g ${gatewayUser} ${daemonState}
    if [ ! -s ${tokenFile} ]; then
      if [ -s ${legacyTokenFile} ]; then
        mv ${legacyTokenFile} ${tokenFile}
      else
        (umask 077; head -c 48 /dev/urandom | base64 -w0 | tr -d '/+=' > ${tokenFile})
      fi
    fi
    rm -f ${legacyTokenFile}
    chown ${gatewayUser}:${gatewayUser} ${tokenFile}
    chmod 0600 ${tokenFile}
  '';

  # Runs as root (pirc-proxy-secret.service): creates the shared secret once,
  # and on every boot the nginx snippet in /run (a tmpfs) that sends it.
  ensureProxySecret = pkgs.writeShellScript "pirc-proxy-secret" ''
    set -eu
    PATH=${lib.makeBinPath [ pkgs.coreutils ]}
    install -d -m 0700 -o ${gatewayUser} -g ${gatewayUser} ${daemonState}
    if [ ! -s ${proxySecretFile} ]; then
      (umask 077; head -c 48 /dev/urandom | base64 -w0 | tr -d '/+=' > ${proxySecretFile})
    fi
    chown ${gatewayUser}:${gatewayUser} ${proxySecretFile}
    chmod 0600 ${proxySecretFile}
    install -d -m 0750 -o root -g ${nginxGroup} ${proxySecretDir}
    snippet=${proxySecretDir}/proxy-secret.conf
    (umask 077; printf 'proxy_set_header X-Pirc-Proxy-Secret "%s";\n' "$(cat ${proxySecretFile})" > "$snippet.tmp")
    chown root:${nginxGroup} "$snippet.tmp"
    chmod 0640 "$snippet.tmp"
    mv -f "$snippet.tmp" "$snippet"
  '';

  # Remote nodes may be added through PIRC_NODE_TOKENS in environmentFile;
  # the local node's token is merged in.
  gatewayStart = pkgs.writeShellScript "pirc-gateway" ''
    set -eu
    ${lib.optionalString useProxySecret ''
      PIRC_PROXY_SECRET=$(cat ${proxySecretFile})
      export PIRC_PROXY_SECRET
    ''}
    ${lib.optionalString cfg.localNode.enable ''
      token=$(cat ${tokenFile})
      remote=''${PIRC_NODE_TOKENS:-}
      [ -n "$remote" ] || remote='{}'
      PIRC_NODE_TOKENS=$(printf '%s' "$remote" \
        | ${pkgs.jq}/bin/jq -c --arg id ${lib.escapeShellArg cfg.localNode.id} --arg token "$token" '. + {($id): $token}')
      export PIRC_NODE_TOKENS
    ''}
    exec ${lib.getExe cfg.gatewayPackage}
  '';

  nodeStart = pkgs.writeShellScript "pirc-node" ''
    set -eu
    PIRC_NODE_TOKEN=$(cat "$CREDENTIALS_DIRECTORY/node-token")
    export PIRC_NODE_TOKEN
    exec ${lib.getExe cfg.nodePackage}${lib.optionalString cfg.chat " chat"}
  '';

  hardening = {
    NoNewPrivileges = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectHome = true;
    ProtectSystem = "strict";
    # No ProtectKernelTunables here: its read-only mounts inside /proc make
    # the kernel refuse bubblewrap's fresh /proc in the agent's PID
    # namespace, so no agent could start. The gateway sets it.
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    # Chromium and user tools may need executable JIT memory (the Rust
    # executables and QuickJS interpreter themselves do not).
    MemoryDenyWriteExecute = false;
    # Both run as ordinary accounts and need no capabilities. bubblewrap's
    # user namespaces get a full set of their own whatever the bounding set.
    CapabilityBoundingSet = "";
    RestrictRealtime = true;
    # Netlink for getaddrinfo and bubblewrap's loopback setup.
    RestrictAddressFamilies = [
      "AF_UNIX"
      "AF_INET"
      "AF_INET6"
      "AF_NETLINK"
    ];
    UMask = "0077";
    Restart = "on-failure";
    RestartSec = 3;
  };

  # The gateway only serves HTTP and runs apiKeyCommand. The node is left
  # without these: bubblewrap mounts and creates namespaces (not in
  # @system-service) and mounts its own /proc, and agents and terminals run
  # the user's tools.
  gatewayHardening = hardening // {
    ProtectKernelTunables = true;
    SystemCallFilter = [ "@system-service" ];
    SystemCallArchitectures = "native";
    ProtectProc = "invisible";
    RestrictNamespaces = true;
  };

  # File-managed providers live on the gateway, which resolves their keys and
  # runs every model request; nodes only get a secret-free catalog. The file
  # sits at a stable /etc path so a change reloads the gateway (SIGHUP).
  # Web-managed backends and subscription logins are kept in stateDirectory.
  # API keys must use apiKeyEnv/apiKeyFile/apiKeyCommand, never literal values.
  modelsFile = pkgs.writeText "pirc-models.json" (json cfg.models);

  # Node-local agent config (limits, features, hooks, ...), kept in the store.
  agentConfigDir = pkgs.runCommand "pirc-agent-config" { } (
    ''
      mkdir -p $out
      cp ${pkgs.writeText "pirc-agent-config.json" (json cfg.agentConfig)} $out/config.json
    ''
    + lib.optionalString (cfg.agentPrompt != null) ''
      cp ${pkgs.writeText "AGENTS.md" cfg.agentPrompt} $out/AGENTS.md
    ''
    + lib.optionalString (cfg.skills != { }) (
      ''
        mkdir -p $out/skills
      ''
      + lib.concatStrings (
        lib.mapAttrsToList (name: dir: ''
          ln -s ${lib.escapeShellArg "${dir}"} $out/skills/${lib.escapeShellArg name}
        '') cfg.skills
      )
    )
  );

  gatewayUpstream = "http://${cfg.listenAddress}:${toString cfg.port}";
in
{
  imports = [
    (mkRemovedOptionModule [
      "services"
      "pirc"
      "chatPackage"
    ] "The chat role now runs nodePackage's pirc-node chat; set services.pirc.nodePackage instead.")
    (mkRemovedOptionModule [
      "services"
      "pirc"
      "package"
    ] "pirc is now two native packages; set services.pirc.gatewayPackage and nodePackage as needed.")
    (mkRemovedOptionModule [
      "services"
      "pirc"
      "piPackage"
    ] "pirc now runs its built-in agent on pirc-node; configure it with services.pirc.agentConfig.")
    (mkRemovedOptionModule [
      "services"
      "pirc"
      "piArgs"
    ] "pirc now runs its built-in agent on pirc-node; configure it with services.pirc.agentConfig.")
    (mkRenamedOptionModule [ "services" "pirc" "hostId" ] [ "services" "pirc" "localNode" "id" ])
    (mkRemovedOptionModule [
      "services"
      "pirc"
      "runnerLimit"
    ] "Runners are no longer limited; concurrent writes are serialized by the node's write broker.")
    (mkRemovedOptionModule
      [
        "services"
        "pirc"
        "sandbox"
        "enable"
      ]
      "Agents always run in the OS sandbox; a node where it cannot work starts no agents. Tune it with services.pirc.agentConfig.sandbox."
    )
  ];

  options.services.pirc = {
    enable = mkEnableOption "pirc gateway, built-in agent and web UI";

    gatewayUser = mkOption {
      type = types.str;
      default = "pirc-gateway";
      description = ''
        Account (and group) the gateway runs as, apart from the node's
        `user`, so agents cannot read the gateway's keys and logins. Files
        named by apiKeyFile must be readable by it.
      '';
    };

    localNode = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Run `pirc-node` (or `pirc-node chat` when chat is enabled) on this host
          as service `pirc-node` so its
          workspaces can host sessions. The gateway itself never runs agents;
          disable this for a routing-only gateway that serves remote nodes.
        '';
      };
      id = mkOption {
        type = types.strMatching "[a-zA-Z0-9_-]{1,100}";
        default = config.networking.hostName;
        defaultText = literalExpression "config.networking.hostName";
        description = "Node ID of the local node; workspaces appear as `<id>:<workspace>`.";
      };
      environmentFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = "/run/secrets/pirc-node-env";
        description = ''
          Optional systemd EnvironmentFile for the local node only, e.g.
          tokens the agents' own tools need (GITHUB_TOKEN). The gateway's
          environmentFile is not given to the node.
        '';
      };
    };

    gatewayPackage = mkOption {
      type = types.package;
      default = pkgs.pirc-gateway or (pkgs.callPackage ./package.nix { role = "gateway"; });
      defaultText = literalExpression "pkgs.pirc-gateway";
      description = "Independent pirc-gateway package, including the web UI.";
    };

    nodePackage = mkOption {
      type = types.package;
      default = pkgs.pirc-node or (pkgs.callPackage ./package.nix { role = "node"; });
      defaultText = literalExpression "pkgs.pirc-node";
      description = "Independent pirc-node package used for the local coding node.";
    };

    models = mkOption {
      type = types.attrsOf types.anything;
      default = { };
      example = literalExpression ''
        {
          providers.openai = {
            api = "openai-completions";
            baseUrl = "https://api.openai.com/v1";
            apiKeyFile = "/run/secrets/openai-key";
            models = [ { id = "gpt-5"; reasoning = true; contextWindow = 400000; } ];
          };
          defaultModel = { provider = "openai"; id = "gpt-5"; };
        }
      '';
      description = ''
        Model providers and the default model, held by the gateway
        (`models.json`) and pushed to every node, local and remote. The
        gateway resolves keys: reference them with apiKeyEnv (set in
        environmentFile), apiKeyFile or apiKeyCommand, which run as the
        gateway's account; literal apiKey values would land in the Nix store.
        Changes reload the gateway and apply to agents started afterwards.
      '';
    };

    agentConfig = mkOption {
      type = types.attrsOf types.anything;
      default = { };
      example = literalExpression ''
        {
          limits.maxTurns = 300;
          features.sessionTitle.enabled = true;
        }
      '';
      description = ''
        Local node's agent configuration (the contents of config.json in
        PIRC_CONFIG_DIR): limits, features, hooks, env and allowed paths.
        Providers and the default model belong in services.pirc.models.
      '';
    };

    agentPrompt = mkOption {
      type = types.nullOr types.lines;
      default = null;
      description = "Optional global AGENTS.md, read by modes that select the agents:global prompt section.";
    };

    skills = mkOption {
      type = types.attrsOf types.path;
      default = { };
      example = literalExpression ''
        {
          pdf = ./skills/pdf;
          moodle-cli = "''${moodle-cli}/lib/node_modules/moodle-cli";
        }
      '';
      description = ''
        Agent Skills for the local node, linked into PIRC_CONFIG_DIR/skills:
        each value is a directory holding a SKILL.md. The agent lists their
        names and descriptions and reads a skill when a task needs it; the
        programs a skill runs belong in extraPackages.
      '';
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [
        pkgs.git
        pkgs.openssh
      ];
      description = "Programs added to PATH for the agent and its tools.";
    };

    user = mkOption {
      type = types.str;
      default = "pirc";
      description = "Unprivileged account of the local node: its agents, their tools and terminals.";
    };

    group = mkOption {
      type = types.str;
      default = "pirc";
      description = "Primary group of the service account.";
    };

    supplementaryGroups = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Additional groups used to grant access to workspace paths or credentials.";
    };

    stateDirectory = mkOption {
      type = types.str;
      default = "/var/lib/pirc";
      description = "Persistent SQLite, upload, and private agent session storage.";
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/secrets/pirc-env";
      description = ''
        Optional systemd EnvironmentFile of the gateway (not the node) for
        provider credentials, for `EXA_API_KEY` (agents' web_search), for `PIRC_NODE_TOKENS`
        (JSON `{nodeId: token}`) when remote nodes connect to this gateway,
        and optionally for `PIRC_VAPID_PUBLIC_KEY`/`PIRC_VAPID_PRIVATE_KEY`
        (push notifications; without them the gateway makes a key pair once
        and keeps it in its state directory). Do not store secrets in the Nix
        store.
      '';
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Additional non-secret PIRC environment variables.";
    };

    timeZone = mkOption {
      type = types.nullOr types.str;
      default = config.time.timeZone;
      defaultText = literalExpression "config.time.timeZone";
      example = "Asia/Taipei";
      description = ''
        IANA time zone for schedules an agent creates without naming one
        (`PIRC_TIMEZONE`). The web and Android apps default to the device's
        zone. Null: the system's.
      '';
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
    };
    port = mkOption {
      type = types.port;
      default = 8787;
    };
    identityHeader = mkOption {
      type = types.str;
      default = "x-pirc-user";
    };
    trustedProxies = mkOption {
      type = types.listOf types.str;
      default = [
        "127.0.0.1"
        "::1"
      ];
    };
    allowedUsers = mkOption {
      type = types.listOf types.str;
      default = [ ];
    };
    allowedOrigins = mkOption {
      type = types.listOf types.str;
      default = [ ];
    };
    allowedHosts = mkOption {
      type = types.listOf types.str;
      default = [ ];
    };
    browser = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Give the local node's agents a Chromium browser (web_fetch and the
          browser_* tools) with one persistent profile per workspace, watched
          and taken over from the Browser side panel (holding session
          control). Not a sandbox: pages load with the pirc account's network
          access and the profile's logins.
        '';
      };
      package = mkOption {
        type = types.package;
        default = pkgs.chromium;
        defaultText = literalExpression "pkgs.chromium";
        description = "Chromium (or Chrome) driven over CDP by the native node.";
      };
      ffmpeg = mkOption {
        type = types.package;
        default = pkgs.ffmpeg-headless;
        defaultText = literalExpression "pkgs.ffmpeg-headless";
        description = "ffmpeg (with libvpx) that encodes browser recordings to WebM.";
      };
    };
    terminals = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Allow interactive shells in the web side panel. Shells run in the
        session's workspace as the pirc account, like the agent's own tools,
        and require holding session control.
      '';
    };
    chat = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Run pirc-node chat instead of pirc-node for the local service: it hosts the
        assistant's chats, a top-level "Chats" plus projects created from
        the web, in directories it manages under its state directory. Keep a
        single chat node on an always-on machine.
      '';
    };
    workspaces = mkOption {
      type = types.attrsOf workspaceType;
      default = { };
      description = "Explicit workspace allowlist of the local node. More can be added from the web.";
    };

    nginx = {
      enable = mkEnableOption "an nginx virtual host for pirc";
      hostName = mkOption {
        type = types.str;
        example = "pirc.example.ts.net";
        description = "Exact public host name. Usually include the same value in allowedHosts.";
      };
      forceSSL = mkOption {
        type = types.bool;
        default = true;
      };
      enableACME = mkOption {
        type = types.bool;
        default = false;
      };
      sslCertificate = mkOption {
        type = types.nullOr types.path;
        default = null;
      };
      sslCertificateKey = mkOption {
        type = types.nullOr types.path;
        default = null;
      };
      forwardAuthUri = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "http://127.0.0.1:9091/api/authz/auth-request";
        description = "Authelia-compatible auth_request endpoint. Required when nginx is enabled.";
      };
      deviceTokens = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Let the native app reach `/api/` with a device token
          (`Authorization: Bearer pirc_dev_…`) instead of forward auth. Such
          requests skip the auth_request check, never carry the identity
          header, and are authenticated by the gateway itself.
        '';
      };
      exposeNodeEndpoint = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Proxy `/node/connect` so remote chat and coding nodes can reach this gateway
          over TLS. It bypasses forward auth: nodes authenticate with their
          PIRC_NODE_TOKENS secret instead.
        '';
      };
      authUserResponseHeader = mkOption {
        type = types.str;
        default = "Remote-User";
        description = "Header returned by forward auth containing the authenticated identity.";
      };
      proxySecret = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Have nginx prove itself to the gateway with a generated shared
          secret (header `X-Pirc-Proxy-Secret`, gateway `PIRC_PROXY_SECRET`).
          Without it, any local process that can connect to the gateway port
          from 127.0.0.1 (agents included, unless network-sandboxed) can claim
          any allowed user. The secret lives in the gateway's state directory
          and in `/run/pirc-nginx` (root and the nginx group only), never in
          the Nix store.
        '';
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = cfg.allowedUsers != [ ];
          message = "services.pirc.allowedUsers must not be empty";
        }
        {
          assertion = cfg.allowedOrigins != [ ];
          message = "services.pirc.allowedOrigins must not be empty";
        }
        {
          assertion = cfg.allowedHosts != [ ];
          message = "services.pirc.allowedHosts must not be empty";
        }
        {
          assertion = !cfg.chat || cfg.workspaces == { };
          message = "services.pirc.chat selects pirc-node chat, which hosts chat workspaces only; move services.pirc.workspaces to another node";
        }
        {
          assertion = cfg.localNode.enable || cfg.workspaces == { };
          message = "services.pirc.workspaces belong to the local node; enable services.pirc.localNode";
        }
        {
          assertion = !(cfg.agentConfig ? providers) && !(cfg.agentConfig ? defaultModel);
          message = "services.pirc.agentConfig.providers/defaultModel moved to services.pirc.models (the gateway pushes them to every node)";
        }
        {
          assertion = !cfg.nginx.enable || cfg.nginx.forwardAuthUri != null;
          message = "services.pirc.nginx.forwardAuthUri is required when nginx is enabled";
        }
      ];

      users.groups.${cfg.group} = { };
      users.users.${cfg.user} = {
        isSystemUser = true;
        group = cfg.group;
        extraGroups = cfg.supplementaryGroups;
        home = cfg.stateDirectory;
        createHome = true;
        # The gateway's directory is inside it: activation resets a home to
        # this mode on every switch (the default 700 would lock it out).
        homeMode = "711";
      };
      users.groups.${gatewayUser} = { };
      users.users.${gatewayUser} = {
        isSystemUser = true;
        group = gatewayUser;
        home = daemonState;
      };

      systemd.tmpfiles.settings.pirc = {
        # Traversable, not listable: each service keeps its own directory.
        ${cfg.stateDirectory}.d = {
          user = cfg.user;
          group = cfg.group;
          mode = "0711";
        };
        # Z: also hands over a daemon directory older versions created as the node's user.
        ${daemonState} = {
          d = {
            user = gatewayUser;
            group = gatewayUser;
            mode = "0700";
          };
          Z = {
            user = gatewayUser;
            group = gatewayUser;
          };
        };
        ${nodeState}.d = {
          user = cfg.user;
          group = cfg.group;
          mode = "0700";
        };
      };

      environment.etc."pirc/models.json".source = modelsFile;

      systemd.services.pirc = {
        description = "pirc gateway";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        environment = gatewayEnvironment;
        # apiKeyCommand runs on the gateway.
        path = cfg.extraPackages;
        reloadTriggers = [ modelsFile ];
        serviceConfig = gatewayHardening // {
          Type = "simple";
          User = gatewayUser;
          Group = gatewayUser;
          WorkingDirectory = daemonState;
          EnvironmentFile = optional (cfg.environmentFile != null) cfg.environmentFile;
          ExecStartPre = optional cfg.localNode.enable "+${ensureToken}";
          ExecStart = gatewayStart;
          ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
          ReadWritePaths = [ daemonState ];
        };
      };
    }

    (mkIf cfg.localNode.enable {
      systemd.services.pirc-node = {
        description = if cfg.chat then "pirc chat host" else "pirc node (agents and shells for this host)";
        wantedBy = [ "multi-user.target" ];
        after = [ "pirc.service" ];
        requires = [ "pirc.service" ];
        path = [ pkgs.bash ] ++ cfg.extraPackages;
        environment = nodeEnvironment;
        serviceConfig = hardening // {
          Type = "simple";
          User = cfg.user;
          Group = cfg.group;
          WorkingDirectory = nodeState;
          EnvironmentFile = optional (cfg.localNode.environmentFile != null) cfg.localNode.environmentFile;
          LoadCredential = [ "node-token:${tokenFile}" ];
          ExecStart = nodeStart;
          # The state directory is also the account's HOME (build caches); the
          # gateway's part of it belongs to another account.
          ReadWritePaths = [ cfg.stateDirectory ] ++ map (workspace: workspace.path) workspaceList;
        };
      };
    })

    (mkIf useProxySecret {
      systemd.services.pirc-proxy-secret = {
        description = "pirc gateway and nginx shared proxy secret";
        wantedBy = [
          "pirc.service"
          "nginx.service"
        ];
        before = [
          "pirc.service"
          "nginx.service"
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = ensureProxySecret;
        };
      };
    })

    (mkIf cfg.nginx.enable {
      services.nginx.enable = true;
      services.nginx.virtualHosts.${cfg.nginx.hostName} = {
        inherit (cfg.nginx) forceSSL enableACME;
        sslCertificate = mkIf (cfg.nginx.sslCertificate != null) cfg.nginx.sslCertificate;
        sslCertificateKey = mkIf (cfg.nginx.sslCertificateKey != null) cfg.nginx.sslCertificateKey;
        root = "${cfg.gatewayPackage}/share/pirc/web";

        locations."= /_pirc_auth" = {
          proxyPass = cfg.nginx.forwardAuthUri;
          extraConfig = ''
            internal;
            ${lib.optionalString cfg.nginx.deviceTokens ''
              # Device tokens are checked by the gateway. No identity is
              # returned, so the identity header is not sent upstream.
              if ($http_authorization ~* "^bearer\s+pirc_dev_") {
                return 200;
              }
            ''}
            proxy_pass_request_body off;
            proxy_set_header Content-Length "";
            proxy_set_header X-Original-URL $scheme://$http_host$request_uri;
            proxy_set_header X-Original-Method $request_method;
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
          '';
        };

        locations."/api/" = {
          proxyPass = gatewayUpstream;
          proxyWebsockets = true;
          extraConfig = ''
            auth_request /_pirc_auth;
            auth_request_set $pirc_user $upstream_http_${
              lib.toLower (builtins.replaceStrings [ "-" ] [ "_" ] cfg.nginx.authUserResponseHeader)
            };
            proxy_set_header ${cfg.identityHeader} $pirc_user;
            ${lib.optionalString useProxySecret ''
              # A glob: build-time validation (no secret there) passes. Should the
              # snippet ever be missing, the gateway refuses every request.
              include ${proxySecretDir}/proxy-secret[.]conf;
            ''}
            proxy_set_header Host $http_host;
            proxy_set_header Origin $http_origin;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          '';
        };

        locations."= /node/connect" = mkIf cfg.nginx.exposeNodeEndpoint {
          proxyPass = gatewayUpstream;
          proxyWebsockets = true;
          extraConfig = ''
            proxy_set_header ${cfg.identityHeader} "";
            proxy_set_header X-Pirc-Proxy-Secret "";
            proxy_read_timeout 1h;
          '';
        };

        locations."/" = {
          tryFiles = "$uri $uri/ /index.html";
          extraConfig = ''
            auth_request /_pirc_auth;
            # Response headers of the static app. `frame-ancestors` only works as a
            # header (the page's own Content-Security-Policy is a <meta> element,
            # added when the bundle is built). Kept in this location: an add_header
            # here replaces those of the enclosing blocks, and the gateway already
            # sets its own headers on /api/.
            add_header Content-Security-Policy "frame-ancestors 'none'" always;
            add_header Referrer-Policy "no-referrer" always;
            add_header X-Content-Type-Options "nosniff" always;
            add_header X-Frame-Options "DENY" always;
          '';
        };
      };
    })
  ]);
}
