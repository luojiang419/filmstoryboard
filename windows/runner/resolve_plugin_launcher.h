#ifndef RUNNER_RESOLVE_PLUGIN_LAUNCHER_H_
#define RUNNER_RESOLVE_PLUGIN_LAUNCHER_H_

#include <string>

struct ResolvePluginLaunchResult {
  bool success;
  std::string code;
  std::string message;
};

ResolvePluginLaunchResult LaunchDaVinciResolveWorkflowIntegration();

#endif  // RUNNER_RESOLVE_PLUGIN_LAUNCHER_H_
