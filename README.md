# Clock26 · 锁屏时钟字体拉伸小插件

一个极简越狱插件：把锁屏大时间的数字换成 Apple 可变字体 **axs66**，用它自带的可变轴做**大小 / 拉高 / 宽度**三种矢量变形——数字任意放大拉伸都清晰不糊，而且**不会被原时间区域裁掉**。

- **三个滑块**：大小（整体放大 0.5–3.0 倍）、拉高（HGHT 高度轴 100–500）、宽度（wdth 宽度轴 60–100）。
- **矢量变形，清晰不糊**：靠字体自身的可变轴 + 点数放大，不是 `transform` 拉伸，放到很大也不模糊、不发虚。
- **不再被切**（本次修复的核心）：放大/拉高后系统给的原时间框太小会切字。插件会围绕原中心**撑开标签自身 frame**，并沿视图链一路到 window **关闭 `clipsToBounds` / `masksToBounds` 并清掉时间区域的 layer 遮罩**，数字溢出原区域也能完整显示。
- **不弹回默认**：每一次 `layoutSubviews` 都重新贴回字体和撑框，配合签名守卫（相同参数直接跳过），系统刷新绝不会把它冲掉。
- **随时可关**：关闭后立即恢复系统原字体与原始尺寸（都做了快照），不留痕迹。

## 原理

系统里藏着一支可变字体 axs66（内部名 `.SF Adaptive Soft Numeric`），带四个可变轴：

| 轴 | 范围 | 作用 | 本插件 |
|------|--------|------|--------|
| **HGHT** | 100–500 | 高度 | ✅「拉高」滑块 |
| **wdth** | 60–100 | 宽度 | ✅「宽度」滑块 |
| wght | 1–1000 | 字重 | 固定 400 |
| SOFT | 0–100 | 圆润度 | 固定 70 |

整体「大小」则是在原始字号上乘一个倍数（0.5–3.0），矢量放大。

为避免与系统隐藏字体同名冲突，随插件附带的 `AXS66Clock.otf` 已用 `rename_font.py` 改名为 `AXS66Clock`（fvar 可变轴保持不变）。插件在进程内用 `CTFontManagerRegisterFontsForURL` 注册它，再对 `CSProminentTimeView` 里最大的数字标签换上带可变轴的 `UIFontDescriptor`，同时撑开标签 frame 并解除祖先裁剪。

## 为什么之前「一超出区域就不显示」

iOS 给锁屏时间的容器既开了 `clipsToBounds`，又在 layer 上挂了显式遮罩（mask）。字号一放大、HGHT 一拉高，字形就超出系统按原字号算好的那个小方框，被这两层裁掉——所以旧版只在原时间区域内可见。现在插件在每次布局里：

1. 把数字标签自身的 `bounds` 按字体实际需要（`sizeThatFits` × 余量）**围绕原中心撑大**（记录首帧原始尺寸，避免逐帧无限膨胀）；
2. 沿视图链到 window 逐层 `clipsToBounds = NO`、`masksToBounds = NO`，并清掉最近几层的 `layer.mask`。

两者一起，放大/拉伸后的数字就能完整溢出显示，不再被切。

## 用法

装好后到「设置 → Clock26」：

- **启用** 开关
- **大小**（倍）滑块：0.5–3.0，默认 1.0
- **拉高**（HGHT）滑块：100–500，默认 300
- **宽度**（wdth）滑块：60–100，默认 100
- 改完即时生效、无需注销；必要时点「注销 Respring」让改动彻底刷新

## 编译

### GitHub Actions（推荐）
推送到仓库后 Actions 自动编译 rootless + roothide 两个 deb，在 Artifacts 里下载。

### 本地 Theos
```bash
# rootless
make clean && make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless

# roothide
make clean && make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
```

## 依赖
- mobilesubstrate（ElleKit / libhooker）
- PreferenceLoader

## 致谢
基于 [LockXTime](https://github.com/xien999/LockXTime)（MIT）的 hook 思路。
