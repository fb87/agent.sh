{
  lib,
  stdenv,
  makeWrapper,
  bash,
  curl,
  jq,
}:

let
  lines = lib.splitString "\n" (builtins.readFile ../agent.sh);
  versionLine = lib.findFirst (line: lib.hasPrefix "VERSION=" line) "" lines;
  version = lib.removeSuffix "\"" (lib.removePrefix "VERSION=\"" versionLine);
  runtimePath = lib.makeBinPath [
    bash
    curl
    jq
  ];
in
stdenv.mkDerivation {
  pname = "agent.sh";
  inherit version;

  src = lib.cleanSource ../.;

  nativeBuildInputs = [ makeWrapper ];

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 agent.sh "$out/libexec/agent.sh"
    # The script looks for pro.mpts beside itself, after the user's prompts
    # in $XDG_CONFIG_HOME/agent.sh/prompts.
    for f in pro.mpts/*.md pro.mpts/commands/*.md; do
      install -Dm644 "$f" "$out/libexec/$f"
    done

    makeWrapper "$out/libexec/agent.sh" "$out/bin/agent.sh" \
      --prefix PATH : "${runtimePath}"

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    "$out/bin/agent.sh" -V | grep -qF "agent.sh ${version}"
    runHook postInstallCheck
  '';

  meta = {
    description = "A coding agent in a single bash file";
    homepage = "https://github.com/fb87/agent.sh";
    license = lib.licenses.mit;
    mainProgram = "agent.sh";
    platforms = lib.platforms.unix;
  };
}
