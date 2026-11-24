#ifndef RUNNER_WINDOWS_DIRECT_P2P_H_
#define RUNNER_WINDOWS_DIRECT_P2P_H_

#include <windows.h>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <functional>
#include <memory>
#include <mutex>
#include <queue>

class WindowsDirectP2pBridge {
 public:
  static constexpr UINT kWmDrainTasks = WM_APP + 101;

  WindowsDirectP2pBridge(flutter::BinaryMessenger* messenger, HWND hwnd);
  ~WindowsDirectP2pBridge();

  WindowsDirectP2pBridge(const WindowsDirectP2pBridge&) = delete;
  WindowsDirectP2pBridge& operator=(const WindowsDirectP2pBridge&) = delete;

  // Must be called from Win32 UI thread when kWmDrainTasks is received.
  void DrainUiTasks();

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void PostUiTask(std::function<void()> task);

  static void OnPeerFoundThunk(const struct WinRtP2pDiscoveredPeer* peer,
                               void* user_data);
  static void OnHotspotStoppedThunk(void* user_data);

  HWND hwnd_ = nullptr;
  bool alive_ = true;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  std::mutex queue_mutex_;
  std::queue<std::function<void()>> ui_tasks_;
};

#endif  // RUNNER_WINDOWS_DIRECT_P2P_H_
