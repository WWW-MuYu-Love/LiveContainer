#import "DecoratedAppSceneViewController.h"
#import "ResizeHandleView.h"
#import "LiveContainerSwiftUI-Swift.h"
#import "AppSceneViewController.h"
#import "UIKitPrivate+MultitaskSupport.h"
#import "PiPManager.h"
#import "VirtualWindowsHostView.h"
#import "../LiveContainer/Localization.h"
#import "utils.h"

@interface DecoratedAppSceneViewController()
@property(nonatomic) NSArray* activatedVerticalConstraints;
@property(nonatomic) NSString* dataUUID;
@property(nonatomic) NSString* bundleId;
@property(nonatomic) int pid;
@property(nonatomic) CGRect originalFrame;
@property(nonatomic) UIButton *czfMaximizeButton;
@property(nonatomic) UIButton *czfMinimizeButton;
@property(nonatomic) UIButton *czfCloseButton;
@property(nonatomic) UIView *czfButtonsContainer;
// 顶部窗口栏的跟随缩放系数（CZF）：内容被缩放比例/固定
// 分辨率缩了多少，栏高、标题字号、三键就同比例缩多少；
// 只缩不放，钳在 0.35–1.0。见 czfSetChromeScale。
@property(nonatomic) CGFloat czfChromeScale;
@property(nonatomic) bool isAppTerminationRequested;
@property(nonatomic) BOOL czfRestoreApplied;
// C1：最大化/还原切换进行中标志——还原 0.3 秒动画内再调
// maximizeWindow 时直接返回，不再起第二套动画抢帧。
@property(nonatomic) BOOL czfMaximizeAnimating;
// C5：窗口动画序号——最小化与恢复各起一次动画时 +1；
// 最小化 completion 只认最新序号，旧动画被新动作打断时
// 不再由旧 completion 落态，改由新动作自己的路径落态。
@property(nonatomic) NSInteger czfWindowAnimSeq;
// 最小化省电（CZF）：YES = 本窗口已最小化，场景应为后台；
// 恢复时清掉。只做标记，真正的 foreground 写在下面三个方法里。
@property(nonatomic) BOOL czfMinimized;
@end

@implementation DecoratedAppSceneViewController

// 窗口按钮胶囊（CZF）：三键装在一个自定义容器里（见建窗
// 处），键直径 = 符号点数 + 14、间距 = 点数一半。符号点数
// 写死 16（原「窗口按钮大小」设置已按 Campbell
// 2026-11-06 令删除）：直径 30、间距 8。
static const CGFloat CZFWindowButtonPointSizeValue = 16.0;

static CGFloat CZFWindowButtonDiameter(void) {
    return CZFWindowButtonPointSizeValue + 14.0;
}

static CGFloat CZFWindowButtonSpacing(void) {
    return round(CZFWindowButtonPointSizeValue * 0.5);
}

// 最大化时收起快捷栏（CZF）：设置页「多任务设置」的
// 开关，键 CZFCollapseDockWhenMaximized（标准
// UserDefaults，与设置页 @AppStorage 同一本）；没设
// 过 = 开。落点见 czfAutoCollapseDockIfNeeded。
static BOOL CZFCollapseDockWhenMaximized(void) {
    NSUserDefaults *d = NSUserDefaults.lcUserDefaults;
    return [d objectForKey:@"CZFCollapseDockWhenMaximized"] == nil || [d boolForKey:@"CZFCollapseDockWhenMaximized"];
}


// 自适应缩放比例（CZF）：设置页「应用设置」的开关，键
// CZFAdaptiveScaleEnabled（标准 UserDefaults，默认
// 关）。开时窗口缩放按“窗口宽 ÷ 全屏宽”自动算（见
// czfApplyAdaptiveScaleRatio）；关时新窗口用默认比例
// CZFWindowScaleRatio（没设过 = 1.0）。都夹在标题菜
// 单滑杆的 0.5–2.0 范围里。
static BOOL CZFAdaptiveScaleEnabled(void) {
    return [NSUserDefaults.lcUserDefaults boolForKey:@"CZFAdaptiveScaleEnabled"];
}

static CGFloat CZFDefaultScaleRatio(void) {
    NSUserDefaults *d = NSUserDefaults.lcUserDefaults;
    if ([d objectForKey:@"CZFWindowScaleRatio"] == nil) {
        return 1.0;
    }
    CGFloat v = [d doubleForKey:@"CZFWindowScaleRatio"];
    if (v < 0.5) v = 0.5;
    if (v > 2.0) v = 2.0;
    return v;
}

- (instancetype)initWindowName:(NSString*)windowName bundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID rootVC:(UIViewController*)rootVC {
    self = [super initWithNibName:nil bundle:nil];
    self.view = [[UIStackView alloc] initWithFrame:self.view.frame];
    [MultitaskDockManager.shared.windowHostingView addSubview:self.view];
    [rootVC addChildViewController:self];
    
    _dataUUID = dataUUID;
    _bundleId = bundleId;
    _scaleRatio = 1.0;
    _czfChromeScale = 1.0;
    // 默认最大化 2026-11-06 改为默认开：键不存在 = 开，
    // 与设置页 @AppStorage 默认值一致（亲手关过仍按关算）
    _isMaximized = [NSUserDefaults.lcUserDefaults objectForKey:@"LCLaunchMultitaskMaximized"] == nil || [NSUserDefaults.lcUserDefaults boolForKey:@"LCLaunchMultitaskMaximized"];
    _appSceneVC = [[AppSceneViewController alloc] initWithBundleId:bundleId dataUUID:dataUUID delegate:self];
    self.title = windowName;
    [self setupDecoratedView];
    
    [MultitaskDockManager.shared addRunningApp:windowName appUUID:dataUUID view:self.view];
    
    NSArray *menuItems = @[
        [UIAction actionWithTitle:@"lc.multitask.copyPid".loc image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction * _Nonnull action) {
            UIPasteboard.generalPasteboard.string = @(self.appSceneVC.pid).stringValue;
        }],
        [UIAction actionWithTitle:@"lc.multitask.enablePip".loc image:[UIImage systemImageNamed:@"pip.enter"] identifier:nil handler:^(UIAction * _Nonnull action) {
            if ([PiPManager.shared isPiPWithVC:self.appSceneVC]) {
                [PiPManager.shared stopPiP];
            } else {
                [PiPManager.shared startPiPWithVC:self.appSceneVC];
            }
        }],
        [UICustomViewMenuElement elementWithViewProvider:^UIView *(UICustomViewMenuElement *element) {
            return [self scaleSliderViewWithTitle:@"lc.multitask.scale".loc min:0.5 max:2.0 value:self.scaleRatio stepInterval:0.01];
        }]
    ];
    

    __weak typeof(self) weakSelf = self;
    [self.navigationItem setTitleMenuProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions){
        if(!weakSelf.appSceneVC.isAppRunning) {
            return [UIMenu menuWithTitle:NSLocalizedString(@"lc.multitaskAppWindow.appTerminated", nil) children:@[]];
        } else {
            NSString *pidText = [NSString stringWithFormat:@"PID: %d", weakSelf.pid];
            return [UIMenu menuWithTitle:pidText children:menuItems];
        }
    }];
    
    // 三键装进一个自定义容器、做成单个 BarButtonItem：系统
    // 胶囊贴着容器大小走，键直径与间距都由点数推导，改设置
    // 时整颗胶囊跟着缩放。旧写法是三个独立 BarButtonItem，
    // 系统给每键固定占位——改点数只有字形变，胶囊和间距
    // 都不动（2026-11-06 Campbell 截图反馈）。
    CGFloat buttonDiameter = CZFWindowButtonDiameter();
    CGFloat buttonSpacing = CZFWindowButtonSpacing();
    UIImageSymbolConfiguration *buttonConfig = [UIImageSymbolConfiguration configurationWithPointSize:CZFWindowButtonPointSizeValue weight:UIImageSymbolWeightMedium];
    
    UIButton *minimizeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.czfMinimizeButton = minimizeButton;
    [minimizeButton setImage:[[UIImage systemImageNamed:@"minus.circle"] imageWithConfiguration:buttonConfig] forState:UIControlStateNormal];
    minimizeButton.tintColor = [UIColor systemYellowColor];
    [minimizeButton addTarget:self action:@selector(minimizeWindow) forControlEvents:UIControlEventTouchUpInside];
    
    NSString *maximizeImageName = _isMaximized ? @"arrow.down.right.and.arrow.up.left.circle" : @"arrow.up.left.and.arrow.down.right.circle";
    self.czfMaximizeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.czfMaximizeButton setImage:[[UIImage systemImageNamed:maximizeImageName] imageWithConfiguration:buttonConfig] forState:UIControlStateNormal];
    self.czfMaximizeButton.tintColor = [UIColor systemGreenColor];
    [self.czfMaximizeButton addTarget:self action:@selector(maximizeWindow) forControlEvents:UIControlEventTouchUpInside];
    
    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.czfCloseButton = closeButton;
    [closeButton setImage:[[UIImage systemImageNamed:@"xmark.circle"] imageWithConfiguration:buttonConfig] forState:UIControlStateNormal];
    closeButton.tintColor = [UIColor systemRedColor];
    [closeButton addTarget:self action:@selector(closeWindow) forControlEvents:UIControlEventTouchUpInside];
    
    BOOL buttonsOnLeft = [NSUserDefaults.lcSharedDefaults boolForKey:@"LCMultitaskBottomWindowBar"];
    // 右侧时视觉顺序 最小化/全屏/关闭；放左侧时与旧版一致，
    // 镜像成 关闭/全屏/最小化。
    NSArray<UIButton *> *orderedButtons = buttonsOnLeft ? @[closeButton, self.czfMaximizeButton, minimizeButton] : @[minimizeButton, self.czfMaximizeButton, closeButton];
    self.czfButtonsContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, buttonDiameter * 3 + buttonSpacing * 2, buttonDiameter)];
    [orderedButtons enumerateObjectsUsingBlock:^(UIButton *button, NSUInteger idx, BOOL *stop) {
        button.frame = CGRectMake(idx * (buttonDiameter + buttonSpacing), 0, buttonDiameter, buttonDiameter);
        [self.czfButtonsContainer addSubview:button];
    }];
    UIBarButtonItem *buttonsItem = [[UIBarButtonItem alloc] initWithCustomView:self.czfButtonsContainer];
    if(buttonsOnLeft) {
        // resize handle overlaps the close button, so put the buttons on the left
        self.navigationItem.leftBarButtonItems = @[buttonsItem];
    } else {
        self.navigationItem.rightBarButtonItems = @[buttonsItem];
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self adjustNavigationBarButtonSpacingWithNegativeSpacing:-8.0 rightMargin:-4.0];
    });

    return self;
}

// MARK: - 窗口状态还原（CZF）
// 关窗/最大化切换/拖动结束时，把窗口的小窗尺寸、归一化位置
// 和全屏状态按 bundleId 存进 lcUserDefaults；下次打开这个
// App 时在 setupDecoratedView 里还原。设置页开关
// CZFRestoreWindowState（键不存在 = 开）控制。
- (BOOL)czfRestoreEnabled {
    NSUserDefaults *d = NSUserDefaults.lcUserDefaults;
    return [d objectForKey:@"CZFRestoreWindowState"] == nil || [d boolForKey:@"CZFRestoreWindowState"];
}

- (NSString *)czfWindowStateKey {
    return [NSString stringWithFormat:@"CZFWinState-%@", self.bundleId ?: self.dataUUID];
}

- (NSDictionary *)czfSavedWindowState {
    if (![self czfRestoreEnabled] || !self.bundleId) {
        return nil;
    }
    return [NSUserDefaults.lcUserDefaults dictionaryForKey:[self czfWindowStateKey]];
}

// 把存的归一化原点反算成实际 frame：必须用系统自己的约定
// （原点 = 归一化值 × maxFrame 尺寸，不加安全区原点偏移——
// updateOriginalFrame 存的时候就是这么存的，加了偏移反而错位）
- (CGRect)czfDenormalizedFrameForState:(NSDictionary *)state {
    CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
    if (CGRectIsEmpty(maxFrame)) {
        maxFrame = UIScreen.mainScreen.bounds;
    }
    CGFloat w = [state[@"w"] doubleValue];
    CGFloat h = [state[@"h"] doubleValue];
    CGFloat ox = [state[@"nx"] doubleValue] * maxFrame.size.width;
    CGFloat oy = [state[@"ny"] doubleValue] * maxFrame.size.height;
    // 夹回可见范围：换过方向/屏幕时别把窗口放飞
    CGRect winBounds = CGRectIsEmpty(self.view.window.bounds) ? UIScreen.mainScreen.bounds : self.view.window.bounds;
    ox = MAX(-w + 60, MIN(ox, winBounds.size.width - 60));
    oy = MAX(0, MIN(oy, winBounds.size.height - 60));
    return CGRectMake(ox, oy, w, h);
}

// 还原的真正落点：窗口建好之后，启动方（LCUtils）会把窗口
// 无条件摆到屏幕正中，setupDecoratedView 里设的 frame 当场被
// 覆盖——这就是前两版大小对、位置永远回正中的根因。改在
// App 初始化完成时再按存的状态摆一次（一次性），这时没人再动它
- (void)czfApplySavedWindowStateIfNeeded {
    if (self.czfRestoreApplied) {
        return;
    }
    self.czfRestoreApplied = YES;
    NSDictionary *savedState = [self czfSavedWindowState];
    if (!savedState || [savedState[@"max"] boolValue]) {
        return;
    }
    CGFloat w = [savedState[@"w"] doubleValue];
    CGFloat h = [savedState[@"h"] doubleValue];
    if (w < 100 || h < 100) {
        return;
    }
    self.view.frame = [self czfDenormalizedFrameForState:savedState];
}

- (void)czfSaveWindowState {
    if (![self czfRestoreEnabled] || !self.bundleId) {
        return;
    }
    CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
    if (CGRectIsEmpty(maxFrame)) {
        return;
    }
    CGFloat nx, ny, w, h;
    if (self.isMaximized) {
        // 最大化时小窗的样子在 originalFrame 里（原点已归一化）
        nx = self.originalFrame.origin.x;
        ny = self.originalFrame.origin.y;
        w = self.originalFrame.size.width;
        h = self.originalFrame.size.height;
    } else {
        // 位置统一从 originalFrame 读：先让系统自己的
        // updateOriginalFrame 按它那套参照系（安全区内的
        // maxFrame）把当前帧刷进去，存取同一套算法，
        // 不再自己另算一套（上一版存时按 maxFrame 归一化、
        // 恢复时按整屏反算，参照系不一致，大小对位置偏）
        [self updateOriginalFrame];
        nx = self.originalFrame.origin.x;
        ny = self.originalFrame.origin.y;
        w = self.originalFrame.size.width;
        h = self.originalFrame.size.height;
    }
    if (w < 50 || h < 50) {
        return;
    }
    NSDictionary *state = @{@"nx": @(nx), @"ny": @(ny), @"w": @(w), @"h": @(h), @"max": @(self.isMaximized)};
    [NSUserDefaults.lcUserDefaults setObject:state forKey:[self czfWindowStateKey]];
}

- (void)setupDecoratedView {
    CGFloat navBarHeight = 44;
    BOOL isLandscape = UIInterfaceOrientationIsLandscape(UIApp.statusBarOrientation);
    CGRect frame = CGRectMake(0, 0, isLandscape ? 480 : 320, (isLandscape ? 320 : 480) + navBarHeight);
    CGPoint rootViewCenter = self.view.superview.center;
    frame.origin = CGPointMake(rootViewCenter.x - frame.size.width / 2, rootViewCenter.y - frame.size.height / 2);

    // 有上次关窗时存的窗口状态就还原它（取代默认居中尺寸）
    NSDictionary *savedState = [self czfSavedWindowState];
    BOOL restored = NO;
    if (savedState) {
        CGFloat sw = [savedState[@"w"] doubleValue];
        CGFloat sh = [savedState[@"h"] doubleValue];
        if (sw >= 100 && sh >= 100) {
            restored = YES;
            _isMaximized = [savedState[@"max"] boolValue];
            if (_isMaximized) {
                self.originalFrame = CGRectMake([savedState[@"nx"] doubleValue], [savedState[@"ny"] doubleValue], sw, sh);
            } else {
                // 这里先摆一次（马上会被启动方的居中覆盖，真
                // 正生效的是初始化完成时 czfApplySavedWindowState
                // 的那一次，两边用同一个反算函数保持一致）
                frame = [self czfDenormalizedFrameForState:savedState];
                self.view.frame = frame;
            }
        }
    }

    if (!restored) {
        if(_isMaximized) {
            CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
            // save origin as normalized coordinates
            frame.origin.x /= maxFrame.size.width;
            frame.origin.y /= maxFrame.size.height;
            self.originalFrame = frame;
        } else {
            self.view.frame = frame;
        }
    }
    
    // Navigation bar
    UINavigationBar *navigationBar = [[UINavigationBar alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width, navBarHeight)];
    navigationBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UINavigationItem *navigationItem = [[UINavigationItem alloc] initWithTitle:self.title];
    navigationBar.items = @[navigationItem];
    
    self.view.axis = UILayoutConstraintAxisVertical;
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.view.layer.cornerRadius = 10;
    self.view.layer.masksToBounds = YES;

    self.navigationBar = navigationBar;
    self.navigationItem = navigationBar.items.firstObject;
    if (!self.navigationBar.superview) {
        [self.view addArrangedSubview:self.navigationBar];
    }
    
    CGRect contentFrame = CGRectMake(0, 0, self.view.frame.size.width, self.view.frame.size.height - navBarHeight);
    UIView *fixedPositionContentView = [[UIView alloc] initWithFrame:contentFrame];
    self.contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    if([NSUserDefaults.lcSharedDefaults boolForKey:@"LCMultitaskBottomWindowBar"]) {
        [self.view insertArrangedSubview:fixedPositionContentView atIndex:0];
    } else {
        [self.view addArrangedSubview:fixedPositionContentView];
    }
    [self.view sendSubviewToBack:fixedPositionContentView];
    
    self.contentView = [[UIView alloc] initWithFrame:contentFrame];
    self.contentView.layer.anchorPoint = self.contentView.layer.position = CGPointMake(0, 0);
    self.contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [fixedPositionContentView addSubview:self.contentView];
    
    UIPanGestureRecognizer *moveGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(moveWindow:)];
    moveGesture.minimumNumberOfTouches = 1;
    moveGesture.maximumNumberOfTouches = 1;
    [self.navigationBar addGestureRecognizer:moveGesture];

    // 双击标题栏切换最大化/还原（maximizeWindow 本身就是切换式）
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(czfTitleBarDoubleTap)];
    doubleTap.numberOfTapsRequired = 2;
    [self.navigationBar addGestureRecognizer:doubleTap];

    // Resize handle (idea stolen from Notes debugging window)
    UIPanGestureRecognizer *resizeGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(resizeWindow:)];
    resizeGesture.minimumNumberOfTouches = 1;
    resizeGesture.maximumNumberOfTouches = 1;
    self.resizeHandle = [[ResizeHandleView alloc] initWithFrame:CGRectMake(self.view.frame.size.width - navBarHeight, self.view.frame.size.height - navBarHeight, navBarHeight, navBarHeight)];
    self.resizeHandle.alpha = _isMaximized ? 0.0 : 1.0;
    [self.resizeHandle addGestureRecognizer:resizeGesture];
    [self.view addSubview:self.resizeHandle];

    // 点按置顶（用户定 2026-10-25）：几个小窗口叠在一起时，点哪个
    // 窗口露出的边角就把哪个顶到最上、不被压住。原来 touchesBegan
    // 那条路收不到游客内容（passthrough view）的触摸——触摸直接
    // 进了游客场景；改走手势识别器：识别器挂在容器视图上，游客
    // 内容的触摸也会经过它；只观察不拦截（cancelsTouchesInView=NO），
    // 不改窗口大小和状态，只调层级。标题栏双击最大化不受影响
    // （单击置顶是空操作级，不等双击判定）。
    UITapGestureRecognizer *raiseTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(czfRaiseWindowOnTap)];
    raiseTap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:raiseTap];
    
    self.view.layer.borderWidth = _isMaximized ? 0.0 : 1.0;
    self.view.layer.borderColor = UIColor.secondarySystemBackgroundColor.CGColor;
    
    [self addChildViewController:_appSceneVC];
    [self.view insertSubview:_appSceneVC.view atIndex:0];
    _appSceneVC.view.translatesAutoresizingMaskIntoConstraints = NO;
    
    [self updateVerticalConstraints];
    [NSLayoutConstraint activateConstraints:@[
        [_appSceneVC.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_appSceneVC.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
    
    
    NSUserDefaults *defaults = NSUserDefaults.lcSharedDefaults;

    [defaults addObserver:self forKeyPath:@"LCMultitaskBottomWindowBar" options:NSKeyValueObservingOptionNew context:NULL];
    [self updateOriginalFrame];
}


// Stolen from UIKitester
- (UIView *)scaleSliderViewWithTitle:(NSString *)title min:(CGFloat)minValue max:(CGFloat)maxValue value:(CGFloat)initialValue stepInterval:(CGFloat)step {
    UIView *containerView = [[UIView alloc] init];
    containerView.translatesAutoresizingMaskIntoConstraints = NO;
    containerView.exclusiveTouch = YES;

    UIStackView *stackView = [[UIStackView alloc] init];
    stackView.axis = UILayoutConstraintAxisVertical;
    stackView.spacing = 0.0;
    stackView.translatesAutoresizingMaskIntoConstraints = NO;
    [containerView addSubview:stackView];
    
    [NSLayoutConstraint activateConstraints:@[
        [stackView.topAnchor constraintEqualToAnchor:containerView.topAnchor constant:10.0],
        [stackView.bottomAnchor constraintEqualToAnchor:containerView.bottomAnchor constant:-8.0],
        [stackView.leadingAnchor constraintEqualToAnchor:containerView.leadingAnchor constant:16.0],
        [stackView.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor constant:-16.0]
    ]];
    
    UILabel *label = [[UILabel alloc] init];
    label.text = title;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont boldSystemFontOfSize:12.0];
    [stackView addArrangedSubview:label];
    
    _UIPrototypingMenuSlider *slider = [[_UIPrototypingMenuSlider alloc] init];
    slider.minimumValue = minValue;
    slider.maximumValue = maxValue;
    slider.value = initialValue;
    slider.stepSize = step;
    
    NSLayoutConstraint *sliderHeight = [slider.heightAnchor constraintEqualToConstant:40.0];
    sliderHeight.active = YES;
    
    [stackView addArrangedSubview:slider];
    
    [slider addTarget:self action:@selector(scaleSliderChanged:) forControlEvents:UIControlEventValueChanged];
    
    return containerView;
}

// 顶部窗口栏跟随内容缩放（Campbell 2026-11-06）：窗口
// 内容被缩放比例缩小时，标题栏也要跟着缩
// ——栏高（在 czfSetChromeScale / updateVerticalConstraints
// 里按 44 × 系数）、标题字号、三键的直径/间距/字形都按
// 同一系数走，不然小窗里栏和按钮显得巨大、还会被系统
// 挤成竖排。系数只缩不放：钳在 0.35–1.0。
// 本方法只刷按钮与字号（约束归 czfSetChromeScale 与
// updateVerticalConstraints 管）；容器还没建好（init 里
// setupDecoratedView 先于按钮创建调用布局）时直接跳过。
- (void)czfRefreshChromeVisuals {
    if (!self.czfButtonsContainer) return;
    CGFloat cs = self.czfChromeScale;
    CGFloat d = CZFWindowButtonDiameter() * cs;
    CGFloat sp = CZFWindowButtonSpacing() * cs;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:CZFWindowButtonPointSizeValue * cs weight:UIImageSymbolWeightMedium];
    [self.czfMinimizeButton setImage:[[UIImage systemImageNamed:@"minus.circle"] imageWithConfiguration:config] forState:UIControlStateNormal];
    NSString *maximizeImageName = _isMaximized ? @"arrow.down.right.and.arrow.up.left.circle" : @"arrow.up.left.and.arrow.down.right.circle";
    [self.czfMaximizeButton setImage:[[UIImage systemImageNamed:maximizeImageName] imageWithConfiguration:config] forState:UIControlStateNormal];
    [self.czfCloseButton setImage:[[UIImage systemImageNamed:@"xmark.circle"] imageWithConfiguration:config] forState:UIControlStateNormal];
    // 按钮在容器里的左右顺序以当前横坐标为准（底部栏换
    // 侧时镜像过），按序重新排位，不写死顺序。
    NSArray<UIView *> *ordered = [self.czfButtonsContainer.subviews sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        CGFloat xa = ((UIView *)a).frame.origin.x;
        CGFloat xb = ((UIView *)b).frame.origin.x;
        return xa < xb ? NSOrderedAscending : (xa > xb ? NSOrderedDescending : NSOrderedSame);
    }];
    [ordered enumerateObjectsUsingBlock:^(UIView *button, NSUInteger idx, BOOL *stop) {
        button.frame = CGRectMake(idx * (d + sp), 0, d, d);
    }];
    CGRect containerFrame = self.czfButtonsContainer.frame;
    containerFrame.size = CGSizeMake(d * 3 + sp * 2, d);
    self.czfButtonsContainer.frame = containerFrame;
    if (cs >= 0.999) {
        self.navigationBar.titleTextAttributes = nil;
    } else {
        self.navigationBar.titleTextAttributes = @{NSFontAttributeName: [UIFont boldSystemFontOfSize:17 * cs]};
    }
    [self.navigationBar setNeedsLayout];
}

// 内容缩放的落点（czfApplyScaleRatio 结尾调用）：记下
// 系数，并把
// 当前已生效的栏高相关约束常量原地改掉——不走动画，
// 标题菜单拖滑杆时栏实时跟随。最大化藏栏中只记系数，
// 还原时由 updateVerticalConstraints 按新系数重建。
- (void)czfSetChromeScale:(CGFloat)scale {
    CGFloat cs = MIN(1.0, MAX(0.35, scale));
    self.czfChromeScale = cs;
    if (self.navigationBar.hidden) {
        return;
    }
    [self czfRefreshChromeVisuals];
    CGFloat h = 44 * cs;
    for (NSLayoutConstraint *c in self.activatedVerticalConstraints) {
        if (c.firstItem == self.navigationBar && c.firstAttribute == NSLayoutAttributeHeight) {
            c.constant = h;
        } else if (c.firstItem == self.appSceneVC.view && c.firstAttribute == NSLayoutAttributeTop) {
            c.constant = h;
        } else if (c.firstItem == self.appSceneVC.view && c.firstAttribute == NSLayoutAttributeBottom) {
            c.constant = -h;
        }
    }
    [self.view layoutIfNeeded];
}

// 缩放比例的统一落点：标题菜单滑杆、自适应、默认比例
// 三条路都走这里（原 scaleSliderChanged 的函数体原样
// 搬过来，行为不变）。
- (void)czfApplyScaleRatio:(CGFloat)ratio {
    self.scaleRatio = ratio;
    self.appSceneVC.scaleRatio = ratio;
    if(self.appSceneVC.usesHostingControllerAPI) {
        self.appSceneVC.contentView.transform = CGAffineTransformMakeScale(ratio, ratio);
    } else {
        self.appSceneVC.contentView.layer.sublayerTransform = CATransform3DMakeScale(ratio, ratio, 1.0);
    }
    [self czfSetChromeScale:ratio];
    __weak typeof(self) weakSelf = self;
    [self.appSceneVC updateFrameWithSettingsBlock:^(UIMutableApplicationSceneSettings *settings) {
        if(weakSelf.isMaximized) {
            [weakSelf updateMaximizedSafeAreaWithSettings:settings];
        } else {
            // it seems some apps don't honor these settings so we don't cover the top of the app
            settings.peripheryInsets = UIEdgeInsetsZero;
            settings.safeAreaInsetsPortrait = UIEdgeInsetsZero;
        }
    }];
}

- (void)scaleSliderChanged:(_UIPrototypingMenuSlider *)slider {
    [self czfApplyScaleRatio:slider.value];
}

// 自适应：比例 = 当前窗口宽 ÷ 全屏（安全区内）宽——整
// 个全屏界面等比缩进窗口里；最大化时自然算得 1.0。
// 参照系与窗口状态还原的反算同一套（maxFrame）。
- (void)czfApplyAdaptiveScaleRatio {
    CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
    if (CGRectIsEmpty(maxFrame)) {
        maxFrame = UIScreen.mainScreen.bounds;
    }
    CGFloat w = self.view.frame.size.width;
    if (maxFrame.size.width <= 0 || w <= 0) {
        return;
    }
    CGFloat r = w / maxFrame.size.width;
    if (r < 0.5) r = 0.5;
    if (r > 2.0) r = 2.0;
    [self czfApplyScaleRatio:r];
}

// 窗口尺寸落定后的统一重算入口（拖动结束、最大化/
// 还原完成）：自适应缩放开时重算；没开就什么都不做，
// 与现状一致。
- (void)czfApplyScalePolicyForCurrentFrame {
    if (CZFAdaptiveScaleEnabled()) {
        [self czfApplyAdaptiveScaleRatio];
    }
}

// 窗口建好、frame 最终落定（场景初始化完成）时调一
// 次：自适应开 → 按宽度算；关 → 默认比例（1.0 时与现
// 状一致，跳过不多跑一轮设置更新）。
- (void)czfApplyInitialScaleRatio {
    if (CZFAdaptiveScaleEnabled()) {
        [self czfApplyAdaptiveScaleRatio];
    } else {
        CGFloat r = CZFDefaultScaleRatio();
        if (r != 1.0) {
            [self czfApplyScaleRatio:r];
        }
    }
}

// 收键盘（宿主侧，三个层次缺一不可，上一轮只做了其中
// 半层才没生效）：
// 1) 本视图 + 游客场景视图 endEditing：宿主侧能摸到的
//    响应者链就这两处，单做本视图没用——游客内容不在本
//    视图的响应者链里；
// 2) sendAction resignFirstResponder：键盘焦点在 iOS 18+
//    托管场景下由宿主的事件转交组件（见 AppSceneViewController
//    的事件转交注释）代理，第一响应者实际挂在宿主进程，
//    向空目标发 resign 才能摸到它；只靠游客进程内 endEditing
//    摸不到这一层；
// 3) Darwin 信号：新游客（TweakLoader 含全局信号观察者）
//    收到后在自己进程内 endEditing；老游客（v184 前启动、
//    TweakLoader 里没新观察者）和禁注入 App（TweakLoader
//    的 constructor 直接 return，见 TweakLoader.m）收不到
//    信号，只能靠上面两层宿主侧收——所以信号只是补刀，
//    不能是唯一手段。
// 信号名改发全局 czf.window.minimize，不再只发按 bid 的：
// 上一轮按 self.bundleId 发，但这个 bundleId 来自启动时
// UserDefaults 的 selected，实际是相对包路径（如 Muse.app
// 这类文件夹名，见 LCUtils 的 launchMultitaskGuestApp 与
// LCAppModel 的 selected 赋值），而游客观察者按
// mainBundle.bundleIdentifier（真实 CFBundleIdentifier）
// 订阅，两边名字永远对不上，信号发了等于没发。全局名不
// 依赖 bid：每个游客只收自己窗口的键盘，没键盘的游客
// endEditing 是空操作，不会误伤别的 App；旧按 bid 的名
// 字也一并发出，兼容其它可能在听它的旧实现。
// 调用方都在主线程（按钮动作、Dock 的 main async），不
// 在这里再切线程。
- (void)czfDismissKeyboard {
    [self.view endEditing:YES];
    if (self.appSceneVC.view) {
        [self.appSceneVC.view endEditing:YES];
    }
    [[UIApplication sharedApplication] sendAction:@selector(resignFirstResponder) to:nil from:nil forEvent:nil];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)@"czf.window.minimize", NULL, NULL, YES);
    if (self.bundleId.length > 0) {
        NSString *minimizeName = [NSString stringWithFormat:@"czf.window.minimize.%@", self.bundleId];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)minimizeName, NULL, NULL, YES);
    }
}

// 最小化省电（CZF）：开关在多任务设置页，键 CZFMinPowerSavingEnabled，
// 键不存在 = 开（跟 CZFRestoreWindowState 同款读法）。关了 = 保持旧行为，
// 最小化只藏视图、场景仍是前台。
- (BOOL)czfMinPowerSavingEnabled {
    NSUserDefaults *d = NSUserDefaults.lcSharedDefaults;
    return [d objectForKey:@"CZFMinPowerSavingEnabled"] == nil || [d boolForKey:@"CZFMinPowerSavingEnabled"];
}

- (void)czfApplyMinimizedForeground {
    BOOL background = self.czfMinimized && [self czfMinPowerSavingEnabled];
    [self.appSceneVC czfSetSceneForeground:!background];
}

// 窗口被叫回台前时调：清最小化标记、恢复前台。只由 Swift 侧
// animateViewAppearance（带取消隐藏的恢复路）调，不由单纯调层级的
// bringViewToFront 调——后者不取消隐藏，调了会让藏着的窗口也变前台。
- (void)czfRestoreFromMinimize {
    // C5：恢复接管最终态——进行中的最小化动画若被这次恢复
    // 打断，它的 completion 凭序号认出自己已过时、不再落态。
    self.czfWindowAnimSeq++;
    self.czfMinimized = NO;
    [self czfApplyMinimizedForeground];
}

- (void)closeWindow {
    self.czfMinimized = NO;
    // 关窗前记下窗口状态，下次打开还原（用户要的核心点）
    [self czfDismissKeyboard];
    [self czfSaveWindowState];
    _isAppTerminationRequested = true;
    if([_appSceneVC isAppRunning]) {
        [_appSceneVC terminate];
    } else {
        [self appSceneVCAppDidExit:self.appSceneVC];
    }
}

- (void)minimizeWindow {
    if (self.view.hidden) return;
    // 最小化先收键盘：只藏窗口视图收不掉键盘——键盘窗口
    // 不随本视图隐藏而消失，游客切最小化后键盘会继续盖在
    // 宿主界面上。动画开始前就收，键盘边收边淡出，不用等
    // 0.3 秒动画跑完；具体分层见 czfDismissKeyboard 注释。
    // 注意：本函数是所有“窗口消失、宿主界面露出来”的必经
    // 之路——快捷栏最小化全部（MultitaskDockManager 的
    // minimizeAllWindows）、面板的最小化打开、LCMaxOneAppOnStage
    // 的自动最小化都调它；视频里从全屏游客回宿主 App 页
    // 也是点标题栏的最小化按钮走这里，没有别的路能把宿
    // 主页顶到全屏游客前面（顶层切换只会把游客窗口带到
    // 前面，见 MultitaskDockManager 的 bringMultitaskViewToFront）。
    [self czfDismissKeyboard];
    // C5：记下本次最小化动画的序号；completion 里只认最新
    // 序号——被更新的最小化/恢复打断的旧动画不再落态。
    NSInteger czfMinAnimSeq = ++self.czfWindowAnimSeq;
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.view.alpha = 0;
        self.view.transform = CGAffineTransformMakeScale(0.1, 0.1);
    } completion:^(BOOL finished) {
        if (czfMinAnimSeq != self.czfWindowAnimSeq) return;
        // C5：中断也落确定态——原来 !finished 直接 return，
        // 视图会停在 alpha=0/scale=0.1 却未 hidden、未最小化、
        // 场景仍前台（看着像窗口没了，实际还在前台占位）。
        // finished 仅用于区分是否跑完，不再决定落不落态。
        (void)finished;
        self.view.hidden = YES;
        self.view.transform = CGAffineTransformIdentity;
        [self.view.superview sendSubviewToBack:self.view];
        // 最小化完成才进后台：动画中途改会跟动画抢场景状态。
        // PiP 不走这里（minimizeWindowPiP 另有路），画中画不受影响。
        self.czfMinimized = YES;
        [self czfApplyMinimizedForeground];
        // 最小化自动关定时器只在有最小化窗口时跑：这里是
        // 所有最小化的必经之路，完成后把定时器踢起来；
        // start 本身幂等，Swift 侧再调也不会叠加。
        [[MultitaskDockManager shared] czfKickMinAutoCloseTimer];
    }];
}

- (void)minimizeWindowPiP {
    // PiP 也一样收键盘：上一轮这条路完全没动，画中画
    // 起来后键盘同样会盖在宿主界面上；PiP 视频本身不受
    // resign 影响（只收第一响应者，不改场景前后台）。
    [self czfDismissKeyboard];
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.view.alpha = 0;
    } completion:^(BOOL finished) {
        self.view.hidden = YES;
    }];
}

- (void)unminimizeWindowPiP {
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.view.hidden = NO;
        self.view.alpha = 1;
    } completion:nil];
}

// 最大化时收起快捷栏（CZF，Campbell 2026-11-06，
// 设置默认开）：窗口进入最大化就把快捷栏收起。两个
// 调用点——maximizeWindow 的完成回调（手动/程序最
// 大化），和 appSceneVC 初始化完成（窗口以最大化状态
// 打开，含默认最大化启动）。还原时不自动展开：收起
// 状态和手动收起完全一致，点快捷栏把手展开即可。
// 收起动作走管理器现成的 toggleDockCollapse，它会
// 连带通知各最大化窗口重算标题栏布局（与既有「收起
// 且最大化才藏标题栏」的规则衔接）。
- (void)czfAutoCollapseDockIfNeeded {
    if (!self.isMaximized) return;
    if (!CZFCollapseDockWhenMaximized()) return;
    if (!MultitaskDockManager.shared.isCollapsed) {
        [MultitaskDockManager.shared toggleDockCollapse];
    }
}

- (void)maximizeWindow {
    // C1：重入守卫——还原 0.3 秒动画内标志还没落位时再调，
    // 旧代码会按旧标志再走一次还原、两套动画同改 frame；
    // 现在进行中直接返回，程序化切换（unmaximizeWindow）
    // 也因此不会二次动画。
    if (self.czfMaximizeAnimating) return;
    self.czfMaximizeAnimating = YES;
    void (^updateSettingsBlock)(UIMutableApplicationSceneSettings *settings);

    [self.view layoutIfNeeded];
    if (self.isMaximized) {
        updateSettingsBlock = ^(UIMutableApplicationSceneSettings *settings) {
            [self updateWindowedFrameWithSettings:settings];
        };
        CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
        CGRect newFrame = CGRectMake(self.originalFrame.origin.x * maxFrame.size.width, self.originalFrame.origin.y * maxFrame.size.height, self.originalFrame.size.width, self.originalFrame.size.height);
        // C1：切换开始时同步落位，不再等 completion 才置 NO。
        self.isMaximized = NO;
        [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            self.view.frame = newFrame;
            self.view.layer.borderWidth = 1;
            self.resizeHandle.alpha = 1;

            [self.appSceneVC updateSettingsWithBlock:updateSettingsBlock];

            [self.view layoutIfNeeded];
        } completion:^(BOOL finished) {
            self.czfMaximizeAnimating = NO;
            [self czfSaveWindowState];
            [self czfApplyScalePolicyForCurrentFrame];
            // 还原成小窗口后重算标题栏布局：2026-11-03 起标题栏
            // 不再随收起 + 最大化自动藏，最大化分支与还原分支
            // 都重算，布局与按钮图标保持同步。
            [self updateVerticalConstraints];
            UIImage *maximizeImage = [UIImage systemImageNamed:@"arrow.up.left.and.arrow.down.right.circle"];
            UIImageConfiguration *maximizeConfig = [UIImageSymbolConfiguration configurationWithPointSize:CZFWindowButtonPointSizeValue * self.czfChromeScale weight:UIImageSymbolWeightMedium];
            [self.czfMaximizeButton setImage:[maximizeImage imageWithConfiguration:maximizeConfig] forState:UIControlStateNormal];
        }];
    } else {
        updateSettingsBlock = ^(UIMutableApplicationSceneSettings *settings) {
            [self updateMaximizedFrameWithSettings:settings];
        };
        [self updateOriginalFrame];
        // C1：原始帧必须在标志还是 NO 时存（updateOriginalFrame
        // 在已最大化时直接返回），存完再同步落位为 YES。
        self.isMaximized = YES;
        [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            [self updateVerticalConstraints];

            self.view.layer.borderWidth = 0;
            self.resizeHandle.alpha = 0;

            [self.appSceneVC updateSettingsWithBlock:updateSettingsBlock];

            [self.view layoutIfNeeded];
        } completion:^(BOOL finished) {
            self.czfMaximizeAnimating = NO;
            [self czfSaveWindowState];
            [self czfApplyScalePolicyForCurrentFrame];
            [self czfAutoCollapseDockIfNeeded];
            UIImage *restoreImage = [UIImage systemImageNamed:@"arrow.down.right.and.arrow.up.left.circle"];
            UIImageConfiguration *restoreConfig = [UIImageSymbolConfiguration configurationWithPointSize:CZFWindowButtonPointSizeValue * self.czfChromeScale weight:UIImageSymbolWeightMedium];
            [self.czfMaximizeButton setImage:[restoreImage imageWithConfiguration:restoreConfig] forState:UIControlStateNormal];
        }];
    }
}

- (void)appSceneVCAppDidExit:(AppSceneViewController*)vc {
    BOOL skipTerminationScreen = [NSUserDefaults.lcSharedDefaults boolForKey:@"LCSkipTerminatedScreen"];
    BOOL isManual = _isAppTerminationRequested;
    if(isManual || skipTerminationScreen) {
        
        MultitaskDockManager *dock = [MultitaskDockManager shared];
        [dock removeRunningApp:self.dataUUID];
        
        self.view.layer.masksToBounds = NO;
        [UIView transitionWithView:self.view duration:0.4 options:UIViewAnimationOptionTransitionCurlUp animations:^{
            self.view.hidden = YES;
        } completion:^(BOOL b){
            [self.view removeFromSuperview];
        }];
        
        if(skipTerminationScreen) {
            [MultitaskRelaunchManager scheduleRelaunchIfNeededWithBundleId:self.appSceneVC.bundleId dataUUID:self.dataUUID isManualTermination:isManual];
        }
    } else {
        UILabel *label = [[UILabel alloc] initWithFrame:self.view.bounds];
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        label.lineBreakMode = NSLineBreakByWordWrapping;
        label.numberOfLines = 0;
        label.text = NSLocalizedString(@"lc.multitaskAppWindow.appTerminated", @"");
        label.textAlignment = NSTextAlignmentCenter;
        [self.view insertSubview:label atIndex:0];
    }
}

- (void)appSceneVC:(AppSceneViewController*)vc didInitializeWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if(error) {
            [vc appTerminationCleanUp];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"lc.common.error".loc message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleCancel handler:nil]];
            [alert addAction:[UIAlertAction actionWithTitle:@"lc.common.copy".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                UIPasteboard.generalPasteboard.string = error.localizedDescription;
            }]];
            [self presentViewController:alert animated:YES completion:nil];
        } else {
            self.pid = vc.pid;
            // 先把窗口摆回上次关窗时的位置（启动方在建窗后
            // 强制居中过，这里摆脱它），再让系统按这个 frame
            // 刷新 originalFrame，后续场景更新都以此为准
            [self czfApplySavedWindowStateIfNeeded];
            [self updateOriginalFrame];
            [self czfApplyInitialScaleRatio];
            // 以最大化状态打开的窗口也算最大化（设置开时
            // 快捷栏自动收起，见 czfAutoCollapseDockIfNeeded）
            [self czfAutoCollapseDockIfNeeded];
            if (self.pidAvailableHandler) {
                self.pidAvailableHandler(@(self.pid), nil);
            }
        }
    });
}

- (void)appSceneVCWillActivateScene:(AppSceneViewController *)vc {
    // Set up initial settings such as frame, safe area, etc
    [self appSceneVC:vc didUpdateFromSettings:vc.presenter.scene.settings.mutableCopy transitionContext:nil lifecycleActionType:0];
}

- (void)appSceneVC:(AppSceneViewController*)vc didUpdateFromSettings:(UIMutableApplicationSceneSettings *)baseSettings transitionContext:(id)newContext lifecycleActionType:(uint32_t)actionType {
    [self.appSceneVC updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
        settings.userInterfaceStyle = baseSettings.userInterfaceStyle;
        settings.interfaceOrientation = baseSettings.interfaceOrientation;
        settings.deviceOrientation = baseSettings.deviceOrientation;
        // 最小化省电：已最小化且开关开时，场景更新也不能把 foreground
        // 刷回 YES，否则下次转屏/改 frame 就失效。宿主路径下这行
        // 本来就被 helper 丢掉，真正生效的是 czfApplyMinimizedForeground
        // 直写的 presenter.scene；这里留着是给 legacy 路径兜底。
        settings.foreground = (self.czfMinimized && [self czfMinPowerSavingEnabled]) ? NO : YES;
        
        if(self.isMaximized) {
            [self updateMaximizedFrameWithSettings:settings];
        } else {
            [self updateWindowedFrameWithSettings:settings];
        }
        CGRect newFrame = CGRectMake(0, 0, self.view.bounds.size.width, self.view.bounds.size.height - self.navigationBar.frame.size.height/self.scaleRatio);
        
        if(UIInterfaceOrientationIsLandscape(baseSettings.interfaceOrientation)) {
            settings.frame = CGRectMake(0, 0, newFrame.size.height, newFrame.size.width);
        } else {
            settings.frame = CGRectMake(0, 0, newFrame.size.width, newFrame.size.height);
        }
    }];
}

- (void)adjustNavigationBarButtonSpacingWithNegativeSpacing:(CGFloat)spacing rightMargin:(CGFloat)margin {
    if (!self.navigationBar) return;
    [self findAndAdjustButtonBarStackView:self.navigationBar withSpacing:spacing rightMargin:margin];
}

- (void)findAndAdjustButtonBarStackView:(UIView *)view withSpacing:(CGFloat)spacing rightMargin:(CGFloat)margin {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:NSClassFromString(@"_UIButtonBarStackView")]) {
            if ([subview respondsToSelector:@selector(setSpacing:)]) {
                [(_UIButtonBarStackView *)subview setSpacing:spacing];
            }
            
            if (subview.superview) {
                for (NSLayoutConstraint *constraint in subview.superview.constraints) {
                    if ((constraint.firstItem == subview && constraint.firstAttribute == NSLayoutAttributeTrailing) ||
                        (constraint.secondItem == subview && constraint.secondAttribute == NSLayoutAttributeTrailing)) {
                        constraint.constant = (constraint.firstItem == subview) ? -margin : margin;
                        break;
                    }
                }
                
                [subview setNeedsLayout];
                [subview.superview setNeedsLayout];
            }
            
            return;
        }
        
        [self findAndAdjustButtonBarStackView:subview withSpacing:spacing rightMargin:margin];
    }
}


- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    [self.view layoutIfNeeded];
    [UIView animateWithDuration:0.3 animations:^{
        BOOL bottomWindowBar = [change[NSKeyValueChangeNewKey] boolValue];
        if(bottomWindowBar) {
            self.navigationItem.leftBarButtonItems = self.navigationItem.rightBarButtonItems;
            self.navigationItem.rightBarButtonItems = nil;
            [self.view addArrangedSubview:self.navigationBar];
        } else {
            self.navigationItem.rightBarButtonItems = self.navigationItem.leftBarButtonItems;
            self.navigationItem.leftBarButtonItems = nil;
            [self.view insertArrangedSubview:self.navigationBar atIndex:0];
        }
        
        // 容器里三键的顺序是按创建时所在侧排的，换侧时把横
        // 坐标镜像一下，保持旧版三个 BarButtonItem 换侧时
        // 的视觉顺序（左：关闭/全屏/最小化；右：反之）。
        for (UIView *button in self.czfButtonsContainer.subviews) {
            CGRect f = button.frame;
            f.origin.x = CGRectGetWidth(self.czfButtonsContainer.bounds) - CGRectGetMaxX(f);
            button.frame = f;
        }
        
        [self updateVerticalConstraints];
        [self adjustNavigationBarButtonSpacingWithNegativeSpacing:-8.0 rightMargin:-4.0];
        
        if(_isMaximized) {
            [self.appSceneVC updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
                [self updateMaximizedFrameWithSettings:settings];
            }];
        }
        [self.view layoutIfNeeded];
    }];
}

- (void)czfTitleBarDoubleTap {
    [self maximizeWindow];
}

// 拖动结束时离可用区域边缘 18pt 内就吸过去：贴边放窗口
// 不用小心翼翼对齐。maxFrame 的算法和最大化/还原保持一致
- (void)czfSnapToEdgesIfNeeded {
    CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
    if (CGRectIsEmpty(maxFrame)) {
        maxFrame = UIScreen.mainScreen.bounds;
    }
    CGRect frame = self.view.frame;
    const CGFloat threshold = 18.0;
    BOOL changed = NO;
    if (fabs(frame.origin.x - CGRectGetMinX(maxFrame)) < threshold) {
        frame.origin.x = CGRectGetMinX(maxFrame);
        changed = YES;
    } else if (fabs(CGRectGetMaxX(frame) - CGRectGetMaxX(maxFrame)) < threshold) {
        frame.origin.x = CGRectGetMaxX(maxFrame) - frame.size.width;
        changed = YES;
    }
    if (fabs(frame.origin.y - CGRectGetMinY(maxFrame)) < threshold) {
        frame.origin.y = CGRectGetMinY(maxFrame);
        changed = YES;
    } else if (fabs(CGRectGetMaxY(frame) - CGRectGetMaxY(maxFrame)) < threshold) {
        frame.origin.y = CGRectGetMaxY(maxFrame) - frame.size.height;
        changed = YES;
    }
    if (changed) {
        [UIView animateWithDuration:0.15 animations:^{
            self.view.frame = frame;
        }];
        [self updateOriginalFrame];
    }
}

- (void)moveWindow:(UIPanGestureRecognizer*)sender {
    if(_isMaximized) return;
    BOOL ended = (sender.state == UIGestureRecognizerStateEnded);

    CGPoint point = [sender translationInView:self.view];
    [sender setTranslation:CGPointZero inView:self.view];

    self.view.center = CGPointMake(self.view.center.x + point.x, self.view.center.y + point.y);
    [self updateOriginalFrame];
    if (ended) {
        // 先吸附再存状态：存下来的是吸附后的位置；顺手修了
        // 以前存状态在应用最后一段位移之前的小偏差
        [self czfSnapToEdgesIfNeeded];
        [self czfSaveWindowState];
    }
}

- (void)resizeWindow:(UIPanGestureRecognizer*)sender {
    if(_isMaximized) return;
    if (sender.state == UIGestureRecognizerStateEnded) {
        [self czfSaveWindowState];
        [self czfApplyScalePolicyForCurrentFrame];
    }

    CGPoint point = [sender translationInView:self.view];
    [sender setTranslation:CGPointZero inView:self.view];

    CGRect frame = self.view.frame;
    frame.size.width = MAX(50, frame.size.width + point.x);
    frame.size.height = MAX(50, frame.size.height + point.y);
    self.view.frame = frame;
    [self updateOriginalFrame];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    // 标题栏等非游客内容区域：按下就置顶。游客内容（passthrough
    // view）的触摸到不了这里，改走 czfRaiseWindowOnTap 手势识别器。
    [self.view.superview bringSubviewToFront:self.view];
}

// 点按置顶：只调层级（与宿主 bringViewToFront 同款：本视图 + 所在
// 窗口），不改大小、不改最大化状态；已在最上时就是空操作
- (void)czfRaiseWindowOnTap {
    [self.view.superview bringSubviewToFront:self.view];
    UIWindow *window = self.view.window;
    if (window.superview) {
        [window.superview bringSubviewToFront:window];
    }
}

- (void)updateVerticalConstraints {
    [self.view layoutIfNeeded];
    [UIView animateWithDuration:0.3 animations:^{
        BOOL bottomWindowBar = [NSUserDefaults.lcSharedDefaults boolForKey:@"LCMultitaskBottomWindowBar"];
        // 用户 2026-11-03 令：最大化最小化栏恢复回来——标题栏
        // 不再随快捷栏收起 + 最大化自动藏（原上游沉浸全屏规则
        // 已废）；收起只收快捷栏本身，不再连带藏标题栏，最大
        // 化时最小化/最大化/关闭按钮一直在。
        // 用户 2026-11-04 13:29 改回：视频为准，收起要全屏满屏
        // （藏标题栏），再点一下显示右上角状态栏加全屏——即
        // 245 的原规则：栏收起且最大化时藏标题栏。
        // （2026-11-06 一度改成最大化一律藏栏、并加了设置开
        // 关，同日 Campbell 令整体改回本规则，开关已撤。）
        BOOL hideWindowBar = MultitaskDockManager.shared.isCollapsed && self.isMaximized;
        // 栏高跟随内容缩放（czfChromeScale，见 czfSetChromeScale）
        CGFloat navBarHeight = hideWindowBar ? 0 : 44 * self.czfChromeScale;
        self.navigationBar.alpha = hideWindowBar ? 0 : 1;
        self.navigationBar.hidden = hideWindowBar;
        
        // Update safe area insets
        if(self.isMaximized) {
            self.appSceneVC.shouldSkipDebounceOnce = YES;
            __weak typeof(self) weakSelf = self;
            [self.appSceneVC updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
                [weakSelf updateMaximizedFrameWithSettings:settings];
            }];
        }
        
        [NSLayoutConstraint deactivateConstraints:self.activatedVerticalConstraints];
        if(bottomWindowBar) {
            self.activatedVerticalConstraints = @[
                [self.appSceneVC.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
                [self.appSceneVC.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-navBarHeight],
                [self.navigationBar.heightAnchor constraintEqualToConstant:navBarHeight]
            ];
        } else {
            self.activatedVerticalConstraints = @[
                [self.appSceneVC.view.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:navBarHeight],
                [self.appSceneVC.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
                [self.navigationBar.heightAnchor constraintEqualToConstant:navBarHeight]
            ];
        }
        [NSLayoutConstraint activateConstraints:self.activatedVerticalConstraints];

        [self.view layoutIfNeeded];
        if (!hideWindowBar) {
            // 藏栏期间只记了系数（czfSetChromeScale），栏一
            // 恢复显示就按当前系数把按钮/字号刷到位
            [self czfRefreshChromeVisuals];
        }
    }];
}

- (UIEdgeInsets)updateMaximizedSafeAreaWithSettings:(UIMutableApplicationSceneSettings *)settings {
    BOOL bottomWindowBar = [NSUserDefaults.lcSharedDefaults boolForKey:@"LCMultitaskBottomWindowBar"];
    UIEdgeInsets safeAreaInsets = self.view.window.safeAreaInsets;
    if(self.navigationBar.hidden) {
        settings.peripheryInsets = safeAreaInsets;
        safeAreaInsets = UIEdgeInsetsZero;
    } else if(bottomWindowBar) {
        // allow the control bar to overlap the bottom safe area
        safeAreaInsets.bottom = 0;
        settings.peripheryInsets = safeAreaInsets;
        safeAreaInsets.top = safeAreaInsets.left = safeAreaInsets.right = 0;
    } else {
        settings.peripheryInsets = UIEdgeInsetsMake(0, safeAreaInsets.left, safeAreaInsets.bottom, safeAreaInsets.right);
        safeAreaInsets.bottom = safeAreaInsets.left = safeAreaInsets.right = 0;
    }
    
    // scale peripheryInsets to match the scale ratio
    settings.peripheryInsets = UIEdgeInsetsMake(settings.peripheryInsets.top/_scaleRatio, settings.peripheryInsets.left/_scaleRatio, settings.peripheryInsets.bottom/_scaleRatio, settings.peripheryInsets.right/_scaleRatio);
    if(UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad) {
        UIInterfaceOrientation currentOrientation = UIApp.statusBarOrientation;
        if(UIInterfaceOrientationIsLandscape(currentOrientation)) {
            safeAreaInsets.top = 0;
        }
        settings.safeAreaInsetsPortrait = LCUIEdgeInsetsRotateToOrientation(settings.peripheryInsets, currentOrientation);

    } else {
        settings.safeAreaInsetsPortrait = UIEdgeInsetsMake(settings.peripheryInsets.top, settings.peripheryInsets.left, settings.peripheryInsets.bottom, settings.peripheryInsets.right);
    }
    
    safeAreaInsets.bottom = 0;
    return safeAreaInsets;
}

- (void)updateMaximizedFrameWithSettings:(UIMutableApplicationSceneSettings *)settings {
    CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, [self updateMaximizedSafeAreaWithSettings:settings]);
    self.view.frame = maxFrame;
}

- (void)updateWindowedFrameWithSettings:(UIMutableApplicationSceneSettings *)settings {
    UIEdgeInsets safeAreaInsets = self.view.window.safeAreaInsets;
    CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, safeAreaInsets);
    settings.peripheryInsets = UIEdgeInsetsZero;
    settings.safeAreaInsetsPortrait = UIEdgeInsetsZero;
    
    CGRect newFrame = CGRectMake(self.originalFrame.origin.x * maxFrame.size.width, self.originalFrame.origin.y * maxFrame.size.height, self.originalFrame.size.width, self.originalFrame.size.height);
    CGPoint center = self.view.center;
    CGRect frame = CGRectZero;
    frame.size.width = MIN(newFrame.size.width, maxFrame.size.width);
    frame.size.height = MIN(newFrame.size.height, maxFrame.size.height);
    CGFloat oobOffset = MAX(30, frame.size.width - 30);
    frame.origin.x = MAX(maxFrame.origin.x - oobOffset, MIN(CGRectGetMaxX(maxFrame) - frame.size.width + oobOffset, center.x - frame.size.width / 2));
    frame.origin.y = MAX(maxFrame.origin.y, MIN(center.y - frame.size.height / 2, CGRectGetMaxY(maxFrame) - frame.size.height));
    [UIView animateWithDuration:0.3 animations:^{
        self.view.frame = frame;
    }];
}

- (void)updateOriginalFrame {
    if(_isMaximized) return;
    CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
    // save origin as normalized coordinates
    self.originalFrame = CGRectMake(self.view.frame.origin.x / maxFrame.size.width, self.view.frame.origin.y / maxFrame.size.height, self.view.frame.size.width, self.view.frame.size.height);
}

@end
