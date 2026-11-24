#include "windows_direct_p2p.h"

#include <flutter/standard_method_codec.h>

#include <string>
#include <thread>

#include "winrt_p2p_core.h"

namespace {

std::string GetStringArg(const flutter::EncodableMap* args,
                         const char* key,
                         const char* fallback = "") {
  if (args == nullptr) return fallback;
  auto it = args->find(flutter::EncodableValue(key));
  if (it != args->end()) {
    if (const auto* s = std::get_if<std::string>(&it->second)) {
      return *s;
    }
  }
  return fallback;
}

int GetIntArg(const flutter::EncodableMap* args,
              const char* key,
              int fallback = 0) {
  if (args == nullptr) return fallback;
  auto it = args->find(flutter::EncodableValue(key));
  if (it != args->end()) {
    if (const auto* i32 = std::get_if<int32_t>(&it->second)) {
      return static_cast<int>(*i32);
    }
    if (const auto* i64 = std::get_if<int64_t>(&it->second)) {
      return static_cast<int>(*i64);
    }
  }
  return fallback;
}

bool GetBoolArg(const flutter::EncodableMap* args,
                const char* key,
                bool fallback = false) {
  if (args == nullptr) return fallback;
  auto it = args->find(flutter::EncodableValue(key));
  if (it != args->end()) {
    if (const auto* b = std::get_if<bool>(&it->second)) {
      return *b;
    }
  }
  return fallback;
}

}  // namespace

WindowsDirectP2pBridge::WindowsDirectP2pBridge(
    flutter::BinaryMessenger* messenger, HWND hwnd)
    : hwnd_(hwnd) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.the356company.sendsnap/direct_p2p",
      &flutter::StandardMethodCodec::GetInstance());

  WinRtP2p_Initialize(&WindowsDirectP2pBridge::OnPeerFoundThunk,
                      &WindowsDirectP2pBridge::OnHotspotStoppedThunk, this);

  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        this->HandleMethodCall(call, std::move(result));
      });
}

WindowsDirectP2pBridge::~WindowsDirectP2pBridge() {
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    alive_ = false;
  }
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
  }
  WinRtP2p_Shutdown();
}

void WindowsDirectP2pBridge::PostUiTask(std::function<void()> task) {
  HWND target_hwnd = nullptr;
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    if (!alive_ || hwnd_ == nullptr) return;
    ui_tasks_.push(std::move(task));
    target_hwnd = hwnd_;
  }
  if (target_hwnd != nullptr) {
    PostMessage(target_hwnd, kWmDrainTasks, 0, 0);
  }
}

void WindowsDirectP2pBridge::DrainUiTasks() {
  for (;;) {
    std::function<void()> task;
    {
      std::lock_guard<std::mutex> lock(queue_mutex_);
      if (!alive_ || ui_tasks_.empty()) return;
      task = std::move(ui_tasks_.front());
      ui_tasks_.pop();
    }
    if (task) {
      task();
    }
  }
}

void WindowsDirectP2pBridge::OnPeerFoundThunk(
    const WinRtP2pDiscoveredPeer* peer, void* user_data) {
  if (peer == nullptr || user_data == nullptr) return;
  auto* self = static_cast<WindowsDirectP2pBridge*>(user_data);
  WinRtP2pDiscoveredPeer copy = *peer;

  self->PostUiTask([self, copy]() {
    if (!self->channel_) return;
    flutter::EncodableMap map;
    map[flutter::EncodableValue("id")] = flutter::EncodableValue(copy.id);
    map[flutter::EncodableValue("name")] = flutter::EncodableValue(copy.name);
    map[flutter::EncodableValue("port")] = flutter::EncodableValue(copy.port);
    map[flutter::EncodableValue("deviceType")] =
        flutter::EncodableValue(copy.device_type);
    map[flutter::EncodableValue("p2pDeviceAddress")] =
        flutter::EncodableValue("");
    map[flutter::EncodableValue("p2pSsid")] =
        flutter::EncodableValue(copy.ssid);
    map[flutter::EncodableValue("p2pPassphrase")] =
        flutter::EncodableValue(copy.passphrase);
    map[flutter::EncodableValue("p2pGoIp")] =
        flutter::EncodableValue(copy.go_ip);
    map[flutter::EncodableValue("airToken")] =
        flutter::EncodableValue(copy.air_token);

    self->channel_->InvokeMethod(
        "onWifiDirectDeviceFound",
        std::make_unique<flutter::EncodableValue>(map));
  });
}

void WindowsDirectP2pBridge::OnHotspotStoppedThunk(void* user_data) {
  if (user_data == nullptr) return;
  auto* self = static_cast<WindowsDirectP2pBridge*>(user_data);
  self->PostUiTask([self]() {
    if (!self->channel_) return;
    flutter::EncodableMap empty_map;
    self->channel_->InvokeMethod(
        "onDirectHotspotReady",
        std::make_unique<flutter::EncodableValue>(empty_map));
  });
}

void WindowsDirectP2pBridge::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());

  if (method == "getDirectStatus") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> shared_res(
        std::move(result));
    std::thread([this, shared_res]() {
      WinRtP2pStatus st{};
      WinRtP2p_GetStatus(&st);
      PostUiTask([shared_res, st]() {
        flutter::EncodableMap map;
        map[flutter::EncodableValue("supported")] =
            flutter::EncodableValue(st.supported);
        map[flutter::EncodableValue("wifiEnabled")] =
            flutter::EncodableValue(st.wifi_enabled);
        map[flutter::EncodableValue("hasPermission")] =
            flutter::EncodableValue(true);
        map[flutter::EncodableValue("locationEnabled")] =
            flutter::EncodableValue(true);
        map[flutter::EncodableValue("bluetoothEnabled")] =
            flutter::EncodableValue(st.bluetooth_enabled);
        map[flutter::EncodableValue("hasBlePermission")] =
            flutter::EncodableValue(true);
        map[flutter::EncodableValue("isGroupActive")] =
            flutter::EncodableValue(st.is_group_active);
        map[flutter::EncodableValue("ssid")] =
            flutter::EncodableValue(st.ssid);
        map[flutter::EncodableValue("passphrase")] =
            flutter::EncodableValue(st.passphrase);
        map[flutter::EncodableValue("goIp")] =
            flutter::EncodableValue(st.go_ip);
        shared_res->Success(flutter::EncodableValue(map));
      });
    }).detach();
    return;
  }

  if (method == "startWifiDirectAdvertising") {
    const std::string id = GetStringArg(args, "id");
    const std::string name = GetStringArg(args, "name", "Windows PC");
    const int port = GetIntArg(args, "port", 53318);
    const std::string air_token = GetStringArg(args, "airToken");

    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> shared_res(
        std::move(result));
    std::thread([this, shared_res, id, name, port, air_token]() {
      WinRtP2pHotspotResult hs{};
      WinRtP2p_StartAdvertising(id.c_str(), name.c_str(), port,
                                air_token.c_str(), &hs);
      PostUiTask([this, shared_res, hs]() {
        if (hs.success && channel_) {
          flutter::EncodableMap hs_map;
          hs_map[flutter::EncodableValue("ssid")] =
              flutter::EncodableValue(hs.ssid);
          hs_map[flutter::EncodableValue("passphrase")] =
              flutter::EncodableValue(hs.passphrase);
          hs_map[flutter::EncodableValue("goIp")] =
              flutter::EncodableValue(hs.go_ip);
          hs_map[flutter::EncodableValue("port")] =
              flutter::EncodableValue(hs.port);
          channel_->InvokeMethod(
              "onDirectHotspotReady",
              std::make_unique<flutter::EncodableValue>(hs_map));
        }
        flutter::EncodableMap res_map;
        res_map[flutter::EncodableValue("success")] =
            flutter::EncodableValue(hs.success);
        res_map[flutter::EncodableValue("error")] =
            flutter::EncodableValue(hs.error);
        shared_res->Success(flutter::EncodableValue(res_map));
      });
    }).detach();
    return;
  }

  if (method == "stopWifiDirectAdvertising") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> shared_res(
        std::move(result));
    std::thread([this, shared_res]() {
      WinRtP2p_StopAdvertising();
      PostUiTask([this, shared_res]() {
        if (channel_) {
          flutter::EncodableMap empty_map;
          channel_->InvokeMethod(
              "onDirectHotspotReady",
              std::make_unique<flutter::EncodableValue>(empty_map));
        }
        shared_res->Success(flutter::EncodableValue(true));
      });
    }).detach();
    return;
  }

  if (method == "startWifiDirectDiscovery") {
    const bool is_passive = GetBoolArg(args, "isPassive", false);
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> shared_res(
        std::move(result));
    std::thread([this, shared_res, is_passive]() {
      bool ok = WinRtP2p_StartDiscovery(is_passive);
      PostUiTask([shared_res, ok]() {
        shared_res->Success(flutter::EncodableValue(ok));
      });
    }).detach();
    return;
  }

  if (method == "setWifiDirectDiscoveryPace") {
    const bool is_passive = GetBoolArg(args, "isPassive", false);
    std::thread([is_passive]() {
      WinRtP2p_SetDiscoveryPace(is_passive);
    }).detach();
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "stopWifiDirectDiscovery") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> shared_res(
        std::move(result));
    std::thread([this, shared_res]() {
      WinRtP2p_StopDiscovery();
      PostUiTask([shared_res]() {
        shared_res->Success(flutter::EncodableValue(true));
      });
    }).detach();
    return;
  }

  if (method == "connectWifiDirectPeer") {
    const std::string ssid = GetStringArg(args, "ssid");
    const std::string pass = GetStringArg(args, "passphrase");
    const std::string go_ip = GetStringArg(args, "goIp");
    const int port = GetIntArg(args, "port", 53318);

    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> shared_res(
        std::move(result));
    std::thread([this, shared_res, ssid, pass, go_ip, port]() {
      WinRtP2pConnectResult cr{};
      WinRtP2p_ConnectToPeer(ssid.c_str(), pass.c_str(), go_ip.c_str(), port,
                             &cr);
      PostUiTask([this, shared_res, cr]() {
        if (channel_) {
          flutter::EncodableMap chg;
          chg[flutter::EncodableValue("connected")] =
              flutter::EncodableValue(cr.success);
          chg[flutter::EncodableValue("goIp")] =
              flutter::EncodableValue(cr.go_ip);
          channel_->InvokeMethod(
              "onDirectConnectionChanged",
              std::make_unique<flutter::EncodableValue>(chg));
        }
        flutter::EncodableMap res_map;
        res_map[flutter::EncodableValue("success")] =
            flutter::EncodableValue(cr.success);
        res_map[flutter::EncodableValue("goIp")] =
            flutter::EncodableValue(cr.go_ip);
        res_map[flutter::EncodableValue("error")] =
            flutter::EncodableValue(cr.error);
        shared_res->Success(flutter::EncodableValue(res_map));
      });
    }).detach();
    return;
  }

  if (method == "disconnectWifiDirect") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> shared_res(
        std::move(result));
    std::thread([this, shared_res]() {
      WinRtP2p_DisconnectDirect();
      PostUiTask([this, shared_res]() {
        if (channel_) {
          flutter::EncodableMap chg;
          chg[flutter::EncodableValue("connected")] =
              flutter::EncodableValue(false);
          chg[flutter::EncodableValue("goIp")] = flutter::EncodableValue("");
          channel_->InvokeMethod(
              "onDirectConnectionChanged",
              std::make_unique<flutter::EncodableValue>(chg));
        }
        shared_res->Success(flutter::EncodableValue(true));
      });
    }).detach();
    return;
  }

  if (method == "startNsdAdvertising" || method == "stopNsdAdvertising" ||
      method == "startNsdDiscovery" || method == "stopNsdDiscovery") {
    result->Success(flutter::EncodableValue(false));
    return;
  }

  result->NotImplemented();
}
