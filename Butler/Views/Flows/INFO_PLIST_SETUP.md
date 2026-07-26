# Info.plist 权限配置说明

## 🚨 如果语音输入崩溃，需要添加以下权限

Butler 应用使用了麦克风和语音识别功能，需要在 `Info.plist` 中添加权限说明。

---

## 📝 必需的权限配置

在你的 **Info.plist** 文件中添加以下键值对：

### 1. 麦克风权限
```xml
<key>NSMicrophoneUsageDescription</key>
<string>Butler 需要访问麦克风来识别你说的物品信息。所有语音数据都在设备本地处理。</string>
```

### 2. 语音识别权限
```xml
<key>NSSpeechRecognitionUsageDescription</key>
<string>Butler 使用语音识别来理解你添加的物品。识别过程完全在本地进行，保护你的隐私。</string>
```

---

## 🔧 如何添加（在 Xcode 中）

### 方法 1：使用 Property List 编辑器

1. 在 Xcode 项目导航器中找到 **Info.plist** 文件
2. 右键点击文件，选择 **Open As → Source Code**
3. 在 `<dict>` 标签内添加上述权限配置
4. 保存文件

### 方法 2：使用图形界面

1. 选择 **Info.plist** 文件
2. 点击列表底部的 **+** 按钮
3. 添加以下两个条目：
   - **Privacy - Microphone Usage Description**
   - **Privacy - Speech Recognition Usage Description**
4. 为每个条目填写使用说明

---

## 📱 完整的 Info.plist 示例

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- 其他配置... -->
    
    <!-- 麦克风权限 -->
    <key>NSMicrophoneUsageDescription</key>
    <string>Butler 需要访问麦克风来识别你说的物品信息。所有语音数据都在设备本地处理。</string>
    
    <!-- 语音识别权限 -->
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Butler 使用语音识别来理解你添加的物品。识别过程完全在本地进行，保护你的隐私。</string>
    
    <!-- 其他配置... -->
</dict>
</plist>
```

---

## ⚠️ 常见问题

### Q: 添加权限后还是崩溃？
A: 尝试以下步骤：
1. 完全删除模拟器中的应用
2. Clean Build Folder (Shift + Cmd + K)
3. 重新运行应用

### Q: 真机上不工作？
A: 确保：
1. Info.plist 中添加了权限说明
2. 在设置 → Butler 中授予了麦克风权限
3. 在设置 → 隐私与安全性 → 语音识别中授予了权限

### Q: 模拟器支持语音识别吗？
A: 模拟器对语音识别的支持有限，建议在真机上测试完整功能。

---

## 🎤 测试权限是否生效

运行应用后：
1. 点击"告诉 Butler"按钮
2. 应该会弹出麦克风权限请求对话框
3. 点击"允许"后才能使用语音功能

如果直接崩溃，说明 Info.plist 配置有问题。
