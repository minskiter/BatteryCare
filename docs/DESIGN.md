# 设计说明

## 品牌：柔和、多彩、明确

BatteryCare 标识以珍珠白圆角方形为底，搭配蓝、青、绿、金、粉、紫的连续光谱电池与白色闪电。柔和投影、细高光与充足留白呼应 macOS 应用图标的精致感。图形为原创向量构成，不包含 Apple 标志，也不是 BetterDisplay 图标的改色版本。

- `assets/logo.svg`：可编辑向量稿，适合网页与设计工具。
- `assets/logo.png`：1024 × 1024 透明画布导出，README 使用。
- `assets/AppIcon.icns`：多尺寸 macOS 图标包。
- `Sources/Icon.swift`：AppKit 确定性绘制版，构建时生成各尺寸 PNG 与 ICNS；阴影和渐变渲染可能与浏览器 SVG 略有差异。

重新导出：

```bash
xcrun swift Sources/Icon.swift assets
```

## 品牌图标不等于充电状态

品牌上的闪电是固定图形。菜单栏图标则必须读取系统的实际 `is_charging`，不能因为开启「自动耗电」就显示闪电。菜单栏仍使用清晰的系统符号，避免缩小多彩 Logo 后丢失状态语义。

## 面板与材质

界面使用 SwiftUI + AppKit 的系统半透明材质，不使用背景截图伪装透明。面板锚定菜单栏按钮，在当前屏幕可见边界内计算位置；支持负坐标的多屏环境与短屏滚动。透明效果会受系统外观、辅助功能「降低透明度」及 macOS 版本影响。

参考 BetterDisplay 的紧凑菜单栏交互，而不是复制其源码、资源或商标。README 的居中品牌区、功能分组、场景表格和边界说明参考维护者自己的 creatorsn-gateway 项目。
