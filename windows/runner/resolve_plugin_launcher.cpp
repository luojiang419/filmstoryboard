#include "resolve_plugin_launcher.h"

#include <UIAutomation.h>
#include <windows.h>
#include <wrl/client.h>

#include <algorithm>
#include <cwctype>
#include <string>
#include <vector>

namespace {

using Microsoft::WRL::ComPtr;

struct ResolveWindowSearch {
  HWND window = nullptr;
};

std::wstring ExecutableNameForWindow(HWND window) {
  DWORD process_id = 0;
  ::GetWindowThreadProcessId(window, &process_id);
  if (process_id == 0) {
    return L"";
  }
  HANDLE process = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                                 process_id);
  if (process == nullptr) {
    return L"";
  }
  wchar_t path[32768] = {};
  DWORD length = static_cast<DWORD>(std::size(path));
  const BOOL read = ::QueryFullProcessImageNameW(process, 0, path, &length);
  ::CloseHandle(process);
  if (!read || length == 0) {
    return L"";
  }
  std::wstring executable(path, length);
  const size_t separator = executable.find_last_of(L"\\/");
  if (separator != std::wstring::npos) {
    executable.erase(0, separator + 1);
  }
  return executable;
}

BOOL CALLBACK FindResolveWindow(HWND window, LPARAM parameter) {
  if (!::IsWindowVisible(window) || ::GetWindow(window, GW_OWNER) != nullptr) {
    return TRUE;
  }
  const std::wstring executable = ExecutableNameForWindow(window);
  if (_wcsicmp(executable.c_str(), L"Resolve.exe") != 0) {
    return TRUE;
  }
  auto* search = reinterpret_cast<ResolveWindowSearch*>(parameter);
  search->window = window;
  return FALSE;
}

std::wstring NormalizedMenuName(const std::wstring& value) {
  std::wstring normalized;
  normalized.reserve(value.size());
  for (wchar_t character : value) {
    if (character == L'&') {
      continue;
    }
    if (character == L'\t') {
      break;
    }
    normalized.push_back(static_cast<wchar_t>(std::towlower(character)));
  }
  while (!normalized.empty() && std::iswspace(normalized.front())) {
    normalized.erase(normalized.begin());
  }
  while (!normalized.empty() && std::iswspace(normalized.back())) {
    normalized.pop_back();
  }
  return normalized;
}

bool MatchesAnyName(const std::wstring& actual,
                    const std::vector<std::wstring>& candidates) {
  const std::wstring normalized_actual = NormalizedMenuName(actual);
  return std::any_of(candidates.begin(), candidates.end(),
                     [&normalized_actual](const std::wstring& candidate) {
                       return normalized_actual ==
                              NormalizedMenuName(candidate);
                     });
}

HRESULT FindNamedMenuItem(IUIAutomation* automation,
                          IUIAutomationElement* root,
                          const std::vector<std::wstring>& names,
                          ComPtr<IUIAutomationElement>* match) {
  VARIANT control_type;
  ::VariantInit(&control_type);
  control_type.vt = VT_I4;
  control_type.lVal = UIA_MenuItemControlTypeId;
  ComPtr<IUIAutomationCondition> condition;
  HRESULT result = automation->CreatePropertyCondition(
      UIA_ControlTypePropertyId, control_type, &condition);
  if (FAILED(result)) {
    return result;
  }

  ComPtr<IUIAutomationElementArray> items;
  result = root->FindAll(TreeScope_Descendants, condition.Get(), &items);
  if (FAILED(result)) {
    return result;
  }
  int count = 0;
  result = items->get_Length(&count);
  if (FAILED(result)) {
    return result;
  }
  for (int index = 0; index < count; ++index) {
    ComPtr<IUIAutomationElement> item;
    if (FAILED(items->GetElement(index, &item))) {
      continue;
    }
    BSTR current_name = nullptr;
    if (FAILED(item->get_CurrentName(&current_name)) || current_name == nullptr) {
      ::SysFreeString(current_name);
      continue;
    }
    const std::wstring name(current_name, ::SysStringLen(current_name));
    ::SysFreeString(current_name);
    if (MatchesAnyName(name, names)) {
      *match = std::move(item);
      return S_OK;
    }
  }
  return HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
}

HRESULT WaitForNamedMenuItem(IUIAutomation* automation,
                             IUIAutomationElement* root,
                             const std::vector<std::wstring>& names,
                             DWORD timeout_ms,
                             ComPtr<IUIAutomationElement>* match) {
  const ULONGLONG deadline = ::GetTickCount64() + timeout_ms;
  HRESULT result = HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
  do {
    result = FindNamedMenuItem(automation, root, names, match);
    if (SUCCEEDED(result) && *match) {
      return S_OK;
    }
    ::Sleep(100);
  } while (::GetTickCount64() < deadline);
  return result;
}

HRESULT ActivateMenuItem(IUIAutomationElement* item, bool prefer_expand) {
  item->SetFocus();
  if (prefer_expand) {
    ComPtr<IUIAutomationExpandCollapsePattern> expand;
    if (SUCCEEDED(item->GetCurrentPatternAs(
            UIA_ExpandCollapsePatternId, IID_PPV_ARGS(&expand))) &&
        expand && SUCCEEDED(expand->Expand())) {
      return S_OK;
    }
  }

  ComPtr<IUIAutomationInvokePattern> invoke;
  if (SUCCEEDED(item->GetCurrentPatternAs(UIA_InvokePatternId,
                                          IID_PPV_ARGS(&invoke))) &&
      invoke && SUCCEEDED(invoke->Invoke())) {
    return S_OK;
  }

  ComPtr<IUIAutomationLegacyIAccessiblePattern> legacy;
  if (SUCCEEDED(item->GetCurrentPatternAs(
          UIA_LegacyIAccessiblePatternId, IID_PPV_ARGS(&legacy))) &&
      legacy) {
    return legacy->DoDefaultAction();
  }
  return UIA_E_NOTSUPPORTED;
}

ResolvePluginLaunchResult Failure(const char* code, const char* message) {
  return {false, code, message};
}

}  // namespace

ResolvePluginLaunchResult LaunchDaVinciResolveWorkflowIntegration() {
  ResolveWindowSearch search;
  ::EnumWindows(FindResolveWindow, reinterpret_cast<LPARAM>(&search));
  if (search.window == nullptr) {
    return Failure("resolve_not_running",
                   "未检测到 DaVinci Resolve，请先启动达芬奇并打开项目");
  }

  ComPtr<IUIAutomation> automation;
  HRESULT result = ::CoCreateInstance(CLSID_CUIAutomation, nullptr,
                                      CLSCTX_INPROC_SERVER,
                                      IID_PPV_ARGS(&automation));
  if (FAILED(result) || !automation) {
    return Failure("automation_unavailable",
                   "Windows 自动化服务不可用，请手动打开“工作区 → 流程整合”");
  }

  ComPtr<IUIAutomationElement> resolve_root;
  result = automation->ElementFromHandle(search.window, &resolve_root);
  if (FAILED(result) || !resolve_root) {
    return Failure(
        "resolve_access_denied",
        "无法访问 DaVinci Resolve 窗口；请确保 Resolve 与 FilmStoryboard 使用相同的管理员权限运行");
  }

  const HWND previous_foreground = ::GetForegroundWindow();
  ::ShowWindow(search.window, SW_RESTORE);
  ::SetForegroundWindow(search.window);

  ComPtr<IUIAutomationElement> workspace;
  result = WaitForNamedMenuItem(automation.Get(), resolve_root.Get(),
                                {L"Workspace", L"工作区"}, 1500,
                                &workspace);
  if (FAILED(result) || !workspace) {
    if (previous_foreground != nullptr) {
      ::SetForegroundWindow(previous_foreground);
    }
    return Failure(
        "workspace_menu_not_found",
        "未在 Resolve 中找到“工作区/Workspace”菜单；请确认权限一致后重试");
  }
  if (FAILED(ActivateMenuItem(workspace.Get(), true))) {
    if (previous_foreground != nullptr) {
      ::SetForegroundWindow(previous_foreground);
    }
    return Failure("workspace_menu_invoke_failed",
                   "无法展开 Resolve“工作区”菜单，请手动启动流程整合插件");
  }

  ComPtr<IUIAutomationElement> desktop_root;
  result = automation->GetRootElement(&desktop_root);
  if (FAILED(result) || !desktop_root) {
    return Failure("automation_root_unavailable",
                   "Windows 自动化桌面服务不可用，请手动启动流程整合插件");
  }

  ComPtr<IUIAutomationElement> integrations;
  result = WaitForNamedMenuItem(
      automation.Get(), desktop_root.Get(),
      {L"Workflow Integrations", L"流程整合", L"工作流集成", L"工作流程集成"},
      2500, &integrations);
  if (FAILED(result) || !integrations) {
    if (previous_foreground != nullptr) {
      ::SetForegroundWindow(previous_foreground);
    }
    return Failure(
        "workflow_integrations_menu_not_found",
        "Resolve 中没有找到“流程整合/Workflow Integrations”菜单，请确认使用 Resolve Studio 且插件已安装");
  }
  if (FAILED(ActivateMenuItem(integrations.Get(), true))) {
    if (previous_foreground != nullptr) {
      ::SetForegroundWindow(previous_foreground);
    }
    return Failure("workflow_integrations_menu_invoke_failed",
                   "无法展开 Resolve“流程整合”菜单，请手动启动插件");
  }

  ComPtr<IUIAutomationElement> plugin;
  result = WaitForNamedMenuItem(
      automation.Get(), desktop_root.Get(),
      {L"FilmStoryboard 时间线桥接", L"FilmStoryboard Timeline Bridge"},
      2500, &plugin);
  if (FAILED(result) || !plugin) {
    if (previous_foreground != nullptr) {
      ::SetForegroundWindow(previous_foreground);
    }
    return Failure(
        "plugin_menu_not_found",
        "未找到“FilmStoryboard 时间线桥接”，请在设置中安装插件并重启 Resolve");
  }
  if (FAILED(ActivateMenuItem(plugin.Get(), false))) {
    if (previous_foreground != nullptr) {
      ::SetForegroundWindow(previous_foreground);
    }
    return Failure("plugin_menu_invoke_failed",
                   "无法调用“FilmStoryboard 时间线桥接”菜单项");
  }

  if (previous_foreground != nullptr) {
    ::SetForegroundWindow(previous_foreground);
  }
  return {true, "ok", "已请求 Resolve 启动 FilmStoryboard 时间线桥接"};
}
