#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreText/CoreText.h>
#import <notify.h>
#import <dlfcn.h>
#import <objc/runtime.h>

// =============================================================================
// Clock26 — 纯「替换字体 + 拉高」小插件
//
// 原理：把锁屏时间数字的字体换成 Apple 的可变字体 axs66（内部 .SF Adaptive Soft
// Numeric，已改名为 AXS66Clock 避免与系统冲突），并驱动它的可变轴：
//   · 大小(Size) —— 在原始点数上乘一个倍数，整体放大（矢量，清晰不糊）
//   · 拉高(HGHT) —— 纵向拉伸，数字变高
//   · 宽度(wdth) —— 横向宽度（60–100，越小越窄）
//
// 关键：放大后系统给标签的原始 frame 太小，会把字形上下/左右切掉（就是"超出
// 原时间区域就不显示"）。所以每次 layoutSubviews 里我们都：
//   1) 把标签自身 bounds 撑到足够容纳放大后的字形（保持系统给的中心，不截断）；
//   2) 沿祖先链一路到 window 关掉 clipsToBounds / masksToBounds（并清掉最近几层的
//      layer.mask），这样长高/变宽的数字不会被时间区域的边框裁掉。
// 字体每次布局都重新贴回，系统刷新冲不掉；签名守卫让重复调用很廉价。
// =============================================================================

#pragma mark - Private framework stubs

typedef NS_OPTIONS(NSUInteger, SBSRelaunchActionOptions) {
    SBSRelaunchActionOptionsNone                  = 0,
    SBSRelaunchActionOptionsRestartRenderServer   = 1 << 0,
    SBSRelaunchActionOptionsFadeToBlackTransition = 1 << 1,
};

@interface NSObject (C26PrivateAPI)
+ (instancetype)actionWithReason:(NSString *)reason options:(SBSRelaunchActionOptions)options targetURL:(NSURL *)targetURL;
+ (instancetype)sharedService;
- (void)sendActions:(NSSet *)actions withResult:(id)result;
@end

#pragma mark - Constants

static NSString *const kPrefsDomain              = @"com.clock26.locktime";
static NSString *const kPrefsChangedNotification = @"com.clock26.locktime/prefsChanged";
static CFStringRef     kDoRespringNotification   = CFSTR("com.clock26.locktime/doRespring");

// The renamed family/PostScript name we ship (see rename_font.py).
static NSString *const kFontPSName = @"AXS66Clock";

// Variable-font axis identifiers (four-char codes as UInt32).
#define C26_FOURCC(a,b,c,d) (((UInt32)(a)<<24)|((UInt32)(b)<<16)|((UInt32)(c)<<8)|(UInt32)(d))
static const UInt32 kAxisHGHT = C26_FOURCC('H','G','H','T'); // height  100..500
static const UInt32 kAxisWDTH = C26_FOURCC('w','d','t','h'); // width    60..100
static const UInt32 kAxisWGHT = C26_FOURCC('w','g','h','t'); // weight    1..1000
static const UInt32 kAxisSOFT = C26_FOURCC('S','O','F','T'); // softness  0..100

#pragma mark - Preference values

static BOOL    pEnabled = YES;
static CGFloat pHeight  = 300.0f;  // HGHT axis value (100 = original, 500 = tallest)
static CGFloat pWidth   = 100.0f;  // wdth axis value (60 = narrow, 100 = full)
static CGFloat pScale   = 1.0f;    // point-size multiplier (1.0 = original size)

#pragma mark - Associated object keys

static char kC26OrigFontKey;   // UILabel -> original UIFont (to restore when off)
static char kC26SigKey;        // UILabel -> last-applied signature string
static char kC26OrigBoundsKey; // UILabel -> original bounds size (NSValue) reference

#pragma mark - Runtime font state

static BOOL gFontRegistered = NO;

#pragma mark - Forward declarations

static void loadPrefs(void);
static void C26ReapplyAll(void);

#pragma mark - Preferences

static void loadPrefs(void) {
    CFArrayRef keyList = CFPreferencesCopyKeyList(
        (CFStringRef)kPrefsDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (keyList) {
        NSDictionary *prefs = (NSDictionary *)CFBridgingRelease(
            CFPreferencesCopyMultiple(keyList, (CFStringRef)kPrefsDomain,
                                      kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
        CFRelease(keyList);
        if (prefs) {
            pEnabled = prefs[@"Enabled"] ? [prefs[@"Enabled"] boolValue]  : YES;
            pHeight  = prefs[@"Height"]  ? [prefs[@"Height"] floatValue]  : 300.0f;
            pWidth   = prefs[@"Width"]   ? [prefs[@"Width"] floatValue]   : 100.0f;
            pScale   = prefs[@"Scale"]   ? [prefs[@"Scale"] floatValue]   : 1.0f;
        }
    }
    pHeight = MAX(100.0f, MIN(500.0f, pHeight));   // HGHT axis range
    pWidth  = MAX(60.0f,  MIN(100.0f, pWidth));    // wdth axis range
    pScale  = MAX(0.5f,   MIN(3.0f,   pScale));    // sane point-size multiplier
}

#pragma mark - Font install path resolution

// Find AXS66Clock.otf across rootful / rootless (/var/jb) / roothide (randomised
// jbroot). Strategy: ask dladdr for the ABSOLUTE path this code was loaded from,
// then walk up parent directories probing the two logical sub-paths the deb
// installs into. Anchoring on the real load path makes it work even when the
// jailbreak root is randomised (roothide), without hard-coding any prefix.
static NSString *C26FontPath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *rels = @[ @"Library/MobileSubstrate/DynamicLibraries/AXS66Clock.otf",
                       @"Library/Application Support/Clock26/AXS66Clock.otf" ];

    Dl_info info; memset(&info, 0, sizeof(info));
    if (dladdr((const void *)&C26FontPath, &info) && info.dli_fname) {
        NSString *dir = [[NSString stringWithUTF8String:info.dli_fname]
                         stringByDeletingLastPathComponent];
        // co-located next to the dylib (rootful DynamicLibraries case)
        NSString *sibling = [dir stringByAppendingPathComponent:@"AXS66Clock.otf"];
        if ([fm fileExistsAtPath:sibling]) return sibling;
        // climb up to the jailbreak root and probe the logical install paths
        NSString *root = dir;
        for (int i = 0; i < 8 && root.length > 1; i++) {
            for (NSString *rel in rels) {
                NSString *cand = [root stringByAppendingPathComponent:rel];
                if ([fm fileExistsAtPath:cand]) return cand;
            }
            root = [root stringByDeletingLastPathComponent];
        }
    }
    // absolute fallbacks for the common schemes
    NSArray *roots = @[ @"", @"/var/jb", @"/var/LIB" ];
    for (NSString *r in roots) {
        for (NSString *rel in rels) {
            NSString *cand = [r stringByAppendingFormat:@"/%@", rel];
            if ([fm fileExistsAtPath:cand]) return cand;
        }
    }
    return nil;   // not found
}

// Register the shipped font with CoreText once, so UIFont(name:) can find it.
static void C26RegisterFontIfNeeded(void) {
    if (gFontRegistered) return;
    // Already available (e.g. re-registered by another process)?
    if ([UIFont fontWithName:kFontPSName size:12.0f]) { gFontRegistered = YES; return; }

    NSString *path = C26FontPath();
    if (!path) return;
    NSURL *url = [NSURL fileURLWithPath:path];
    CFErrorRef err = NULL;
    if (CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url,
                                         kCTFontManagerScopeProcess, &err)) {
        gFontRegistered = YES;
    } else {
        // "already registered" is fine — treat as success.
        if (err) {
            CFIndex code = CFErrorGetCode(err);
            if (code == kCTFontManagerErrorAlreadyRegistered) gFontRegistered = YES;
            CFRelease(err);
        }
    }
}

#pragma mark - Variable font construction

// Build an axs66 UIFont at the given point size with the HGHT (height) and wdth
// (width) axes set; weight/softness left at pleasant defaults. Returns nil if the
// font isn't registered yet.
static UIFont *C26AxsFontOfSize(CGFloat size, CGFloat height, CGFloat width) {
    if (size <= 0) size = 12.0f;
    NSDictionary *variations = @{
        @(kAxisHGHT) : @(height),
        @(kAxisWDTH) : @(width),    // horizontal width 60..100
        @(kAxisWGHT) : @(400),      // regular weight (matches stock clock feel)
        @(kAxisSOFT) : @(70),       // Apple's default softness
    };
    UIFontDescriptor *desc = [UIFontDescriptor fontDescriptorWithFontAttributes:@{
        UIFontDescriptorNameAttribute        : kFontPSName,
        (__bridge NSString *)kCTFontVariationAttribute : variations,
    }];
    UIFont *f = [UIFont fontWithDescriptor:desc size:size];
    // Guard: if the name didn't resolve, fontWithDescriptor may hand back a
    // system fallback whose family isn't ours — reject it so we don't lie.
    if (!f) return nil;
    return f;
}

#pragma mark - View helpers

static NSArray<UILabel *> *C26LabelsInView(UIView *v) {
    NSMutableArray *out = [NSMutableArray array];
    for (UIView *sub in v.subviews) {
        if ([sub isKindOfClass:[UILabel class]]) [out addObject:sub];
        [out addObjectsFromArray:C26LabelsInView(sub)];
    }
    return out;
}

// The big time digits are the largest label in the time view.
static UILabel *C26LargestLabelInView(UIView *v) {
    UILabel *best = nil; CGFloat maxSize = 0;
    for (UILabel *l in C26LabelsInView(v)) {
        if (l.text.length > 0 && l.font.pointSize > maxSize) {
            maxSize = l.font.pointSize; best = l;
        }
    }
    return best;
}

static void C26PreserveOriginalFont(UILabel *label) {
    if (!label || objc_getAssociatedObject(label, &kC26OrigFontKey)) return;
    objc_setAssociatedObject(label, &kC26OrigFontKey, label.font, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Stop ancestors clipping the taller/bigger digits. iOS clips the time both via
// clipsToBounds AND via an explicit CALayer mask on the time container, so we
// disable both up the chain to the window. Clearing the mask on the nearest few
// layers is what actually lets glyphs spill past the stock time rectangle.
static void C26UnclipChain(UIView *view, int levels) {
    UIView *v = view;
    for (int i = 0; v && i < levels; i++) {
        v.clipsToBounds = NO;
        v.layer.masksToBounds = NO;
        // Only strip explicit masks on the nearest few layers (the time-region
        // clip lives here); leave higher containers' masks alone so we don't
        // break unrelated rounded-corner shapes on the lock screen.
        if (i < 3 && v.layer.mask) v.layer.mask = nil;
        v = v.superview;
    }
}

// Enlarge the label's own frame so a scaled-up / taller glyph isn't clipped by
// the tight box the system laid out for the stock size. We grow around the same
// center the system chose (so position is preserved).
//
// IMPORTANT: we must NOT feed an already-grown bounds back into the computation,
// or it would grow without bound every layout pass. So we (a) snapshot the very
// first (system) bounds once, and (b) derive the needed size from the font's own
// metrics via sizeThatFits, which already reflects the enlarged variable font.
static void C26GrowLabelBounds(UILabel *label) {
    if (!label) return;

    // Remember the original (stock) box the first time we see a real layout.
    NSValue *origVal = objc_getAssociatedObject(label, &kC26OrigBoundsKey);
    CGSize origSize;
    if (origVal) {
        origSize = [origVal CGSizeValue];
    } else {
        origSize = label.bounds.size;
        if (origSize.width < 1 || origSize.height < 1) return;  // not laid out yet
        objc_setAssociatedObject(label, &kC26OrigBoundsKey,
            [NSValue valueWithCGSize:origSize], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // How big does the current font actually need to draw the text?
    CGSize fit = [label sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
    // HGHT stretches glyphs vertically beyond normal metrics, so pad height hard.
    CGFloat needW = MAX(origSize.width,  fit.width  * 1.15f);
    CGFloat needH = MAX(origSize.height, fit.height * 1.6f);

    CGRect b = label.bounds;
    if (needW <= b.size.width + 0.5f && needH <= b.size.height + 0.5f) return;

    CGPoint center = label.center;
    CGRect nb = b;
    nb.size.width  = needW;
    nb.size.height = needH;
    label.bounds = nb;
    label.center = center;          // keep where the system put it
    label.textAlignment = NSTextAlignmentCenter;
}

#pragma mark - Apply / restore

static void C26ApplyToLabel(UILabel *label) {
    if (!label) return;
    C26PreserveOriginalFont(label);
    UIFont *orig = objc_getAssociatedObject(label, &kC26OrigFontKey) ?: label.font;

    if (!pEnabled) {                       // restore stock font + box
        if (orig && label.font != orig) label.font = orig;
        NSValue *origVal = objc_getAssociatedObject(label, &kC26OrigBoundsKey);
        if (origVal) {
            CGPoint c = label.center;
            CGRect b = label.bounds; b.size = [origVal CGSizeValue];
            label.bounds = b; label.center = c;
        }
        objc_setAssociatedObject(label, &kC26SigKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    C26RegisterFontIfNeeded();
    CGFloat baseSize = orig.pointSize > 0 ? orig.pointSize : label.font.pointSize;
    CGFloat size = baseSize * pScale;   // point-size multiplier -> overall bigger

    // Skip work if nothing changed since last pass (font is re-asserted every
    // layoutSubviews, so this guard keeps it cheap and avoids fighting layout).
    NSString *sig = [NSString stringWithFormat:@"%@|%.1f|%.1f|%.1f|%.2f",
                     kFontPSName, size, pHeight, pWidth, pScale];
    NSString *cur = objc_getAssociatedObject(label, &kC26SigKey);
    BOOL fontOk = ([label.font.fontName rangeOfString:@"AXS66"].location != NSNotFound);
    if ([cur isEqualToString:sig] && fontOk) {
        // Even when the font is unchanged, keep asserting unclip + bounds because
        // layout may have reset them.
        C26UnclipChain(label, 8);
        C26GrowLabelBounds(label);
        return;
    }

    UIFont *vf = C26AxsFontOfSize(size, pHeight, pWidth);
    if (!vf) return;                       // font not ready yet; try again next pass
    label.font = vf;
    label.adjustsFontSizeToFitWidth = NO;  // let it grow, don't auto-shrink
    label.numberOfLines = 1;
    C26UnclipChain(label, 8);
    C26GrowLabelBounds(label);
    objc_setAssociatedObject(label, &kC26SigKey, sig, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIView *C26FindClass(UIView *v, const char *clsName) {
    Class cls = objc_getClass(clsName);
    if (cls && [v isKindOfClass:cls]) return v;
    for (UIView *sub in v.subviews) {
        UIView *r = C26FindClass(sub, clsName);
        if (r) return r;
    }
    return nil;
}

static void C26ReapplyAll(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                UIView *t = C26FindClass(w, "CSProminentTimeView");
                if (t) C26ApplyToLabel(C26LargestLabelInView(t));
            }
        }
    });
}

#pragma mark - Respring + prefs callbacks

static void performRespring(void) {
    dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
    Class actionClass  = objc_getClass("SBSRelaunchAction");
    Class serviceClass = objc_getClass("FBSSystemService");
    if (!actionClass || !serviceClass) return;
    id restartAction = [actionClass actionWithReason:@"Clock26Prefs"
        options:(SBSRelaunchActionOptionsRestartRenderServer | SBSRelaunchActionOptionsFadeToBlackTransition)
        targetURL:nil];
    if (!restartAction) return;
    [[serviceClass sharedService] sendActions:[NSSet setWithObject:restartAction] withResult:nil];
}

static void doRespringCallback(CFNotificationCenterRef center, void *observer,
                               CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{ performRespring(); });
}

static void prefsChangedCallback(CFNotificationCenterRef center, void *observer,
                                 CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    loadPrefs();
    C26ReapplyAll();
}

#pragma mark - Hooks

%hook CSProminentTimeView
- (void)layoutSubviews {
    %orig;
    // Re-assert the variable font every layout pass so a system refresh can't
    // revert it. The signature guard above makes repeat calls cheap.
    C26ApplyToLabel(C26LargestLabelInView((UIView *)self));
}
%end

%ctor {
    @autoreleasepool {
        loadPrefs();
        C26RegisterFontIfNeeded();
        CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(darwin, NULL, prefsChangedCallback,
            (CFStringRef)kPrefsChangedNotification, NULL, CFNotificationSuspensionBehaviorCoalesce);
        CFNotificationCenterAddObserver(darwin, NULL, doRespringCallback,
            kDoRespringNotification, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        %init;
    }
}
