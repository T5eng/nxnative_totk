// iOS app entry for the MacNativeGames TOTK runtime: set the working directory and environment, keep Documents/log.txt,
// then create the Metal view (runtime/frontend_ios.m) and run the loader on a dedicated game thread with a large stack.
// The guest modules are embedded in this executable (Gen/embed.S + ios_embed.h): iOS cannot execute code written at run time.
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "runtime.h"
#include <fcntl.h>

int totk_loader_main(int argc, char **argv);

/* The runtime's 3D brightness hook (weak dm_bright_k in nvn_mtl.m). TOTK_BRIGHT=<k> sets the exposure applied in PQ space
   before the game's tone-map LUT; TOTK_HDR=1 (prototype) uses a lifted default. 1.0 keeps the original picture. */
float dm_bright_k(void);              // runtime/loader.c compiled with -Dmain=totk_loader_main
void runtime_ios_attach_layer(CAMetalLayer *layer, UIView *host);
void runtime_front_run(void (*callback)(void));

@interface TOTKView : UIView
@end
@implementation TOTKView
+ (Class)layerClass { return CAMetalLayer.class; }
@end

// The Mac front end owns this hint overlay; on iOS there is no keyboard hint bar (key 1 has no effect).
void runtime_shortcut_help_toggle(void) {}

static NSString *g_doc;

float dm_bright_k(void) {
    static float v = -1;
    if (v >= 0) return v;
    const char *e = getenv("TOTK_BRIGHT");
    if (e && *e) { v = strtof(e, NULL); if (!(v > 0.0f) || v > 8.0f) v = 1.0f; }
    else if (getenv("TOTK_HDR") && atoi(getenv("TOTK_HDR"))) v = 2.2f;
    else v = 1.0f;
    fprintf(stderr, "[totk-ios] 3D brightness exposure %.2f\n", v);
    return v;
}

static void ensure_dir(NSString *p) {
    [NSFileManager.defaultManager createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:nil];
}

// Environment switches for on-device diagnostics: one KEY=VALUE per line in Documents/env.txt (a sideloaded app cannot get
// environment variables from outside). Lines starting with # are ignored; empty values are allowed.
static void load_env_file(NSString *path) {
    NSString *txt = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    for (NSString *raw in [txt componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *ln = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSRange eq = [ln rangeOfString:@"="];
        if (!ln.length || [ln hasPrefix:@"#"] || eq.location == NSNotFound || eq.location == 0) continue;
        setenv([[ln substringToIndex:eq.location] UTF8String], [[ln substringFromIndex:eq.location + 1] UTF8String], 1);
    }
}

static void boot_env(void) {
    g_doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    chdir(g_doc.fileSystemRepresentation);              // the runtime's relative paths (extracted/…, shader-cache/…) live here
    for (NSString *d in @[@"extracted/v143/romfs", @"extracted/v143/romfs-patches", @"shared-fonts", @"save", @"temp"])
        ensure_dir([g_doc stringByAppendingPathComponent:d]);
    // The host writes diagnostics to stderr only: keep the current log and the previous one in Documents (Files app).
    NSString *log = [g_doc stringByAppendingPathComponent:@"log.txt"], *prev = [g_doc stringByAppendingPathComponent:@"log.prev.txt"];
    [NSFileManager.defaultManager removeItemAtPath:prev error:nil];
    [NSFileManager.defaultManager moveItemAtPath:log toPath:prev error:nil];
    if (freopen(log.fileSystemRepresentation, "w", stderr)) setvbuf(stderr, NULL, _IOLBF, 0);
    setenv("TOTK_ROMFS", "extracted/v143/romfs", 0);
    setenv("TOTK_SHARED_FONTS", "shared-fonts", 0);
    setenv("TOTK_ROMFS_PROOF_DIR", g_doc.fileSystemRepresentation, 0);
    setenv("TOTK_ROMFS_PATCHES", "0", 0);               // the 1.4.3 overlays are optional; enable by putting them in Documents
    // The Mac launcher's defaults (app/launcher.m): without the GPU switches the graphics layer is inert and partial clears abort.
    setenv("TOTK_PROFILE_DIR", "profile", 0);
    setenv("TOTK_GAME_SLOT_DIR", "game-slot", 0);
    setenv("TOTK_GPU_ALLOW_SUBMIT", "1", 0);
    setenv("TOTK_GPU_WIDEN", "1", 0);
    setenv("TOTK_GPU_BLOCKRT", "1", 0);
    setenv("TOTK_GPU_MIDCLEAR", "1", 0);
    setenv("TOTK_GPU_BUDGET_MB", "3500", 0);            // iPhone Air 8 GB: the Mac uses 5000
    // The background pipeline warm reads MSL sources for variants that may only have a precompiled metallib on the phone
    // (not yet fully source-consistent) and crashed there; the title and draws load shaders lazily, so warm is off for now.
    setenv("DM_PSO_MANIFEST", "off", 0);
    setenv("TOTK_WARM_LIGHT", "0", 0);
    unsetenv("TOTK_AUTOLOAD");                          // start at the title screen, as on the console
    // Remote diagnostics: lines appended to Documents/input.txt drive screenshots / thread dumps / pass dumps while the game
    // runs (runtime/input.c). The constructors ran before this env file was read, so start the reader here.
    setenv("TOTK_INPUT_FILE", [g_doc stringByAppendingPathComponent:@"input.txt"].fileSystemRepresentation, 0);
    setenv("TOTK_INPUT_REOPEN", "1", 0);   // the file is replaced over AFC; the reader reopens it when that happens
    { int fd = open([g_doc stringByAppendingPathComponent:@"input.txt"].fileSystemRepresentation, O_CREAT | O_RDONLY, 0644); if (fd >= 0) close(fd); }
    // Read env.txt before starting the services below: their start-up decisions (TOTK_AUTOLOAD, the command queue) are taken
    // once, from the environment as it is now.
    load_env_file([g_doc stringByAppendingPathComponent:@"env.txt"]);
    runtime_input_file_start();
    setenv("TOTK_CMD_DIR", [g_doc stringByAppendingPathComponent:@"cmds"].fileSystemRepresentation, 0);
    [[NSFileManager defaultManager] createDirectoryAtPath:[g_doc stringByAppendingPathComponent:@"cmds"] withIntermediateDirectories:YES attributes:nil error:nil];
    runtime_cmd_dir_start();
    runtime_autoload_start();   // TOTK_AUTOLOAD: the constructor ran before this env file was read
    fprintf(stderr, "[totk-ios] %.3f launch: %s\n", (double)clock() / CLOCKS_PER_SEC, g_doc.fileSystemRepresentation);
}

static void run_loader(void) {
    char *argv[3] = {(char *)"totk", (char *)"/unused", (char *)"boot"};
    totk_loader_main(3, argv);
}

// Debug: TOTK_IOS_SHOT=<n> (default 0) writes n PNG snapshots of the window to Documents/shot_<k>.png, 3 s apart,
// starting 25 s after the first frame. Metal layers are captured through drawViewHierarchy (framebufferOnly is off).
static void schedule_screenshots(UIWindow *w, int n) {
    for (int i = 0; i < n; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((25 + 3 * i) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *root = w.rootViewController.view;
            if (!root) return;
            UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:root.bounds.size];
            UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                (void)ctx; [root drawViewHierarchyInRect:root.bounds afterScreenUpdates:YES];
            }];
            NSString *p = [g_doc stringByAppendingPathComponent:[NSString stringWithFormat:@"shot_%d.png", i]];
            [UIImagePNGRepresentation(img) writeToFile:p atomically:YES];
            fprintf(stderr, "[totk-ios] screenshot %d -> %s\n", i, p.UTF8String);
        });
    }
}

static void *game_thread(void *arg) {
    (void)arg;
    @autoreleasepool { runtime_front_run(run_loader); }
    return NULL;
}

// iOS 26+ enforces the scene lifecycle: the window and the Metal view belong to the scene delegate. The app delegate only
// prepares the working directory/environment before the first scene connects.
@interface TOTKAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation TOTKAppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    (void)app; (void)opts;
    boot_env();
    return YES;
}
@end

@interface TOTKSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation TOTKSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)session; (void)options;
    UIWindowScene *ws = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:ws];
    UIViewController *vc = [UIViewController new];
    TOTKView *view = [[TOTKView alloc] initWithFrame:self.window.bounds];
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    vc.view = view;
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    // Attach after the first layout so the layer size and screen scale are known, then start the game thread.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        runtime_ios_attach_layer((CAMetalLayer *)view.layer, view);
        extern void runtime_touch_controls_install(UIView *host);   // Sources/touch_controls.m
        runtime_touch_controls_install(view);
        { const char *e = getenv("TOTK_IOS_SHOT"); int n = e ? atoi(e) : 0; if (n > 0) schedule_screenshots(self.window, n); }
        pthread_attr_t attr; pthread_attr_init(&attr);
        pthread_attr_setstacksize(&attr, 64 << 20);     // the guest's main thread runs on this host thread
        pthread_t t;
        if (pthread_create(&t, &attr, game_thread, NULL)) { fprintf(stderr, "[totk-ios] game thread create failed\n"); exit(1); }
        pthread_detach(t);
    });
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // Reserve the guest window before UIKit/Metal map their own regions (see services.c memory_init).
        runtime_reserve_guest_memory();
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(TOTKAppDelegate.class));
    }
}
