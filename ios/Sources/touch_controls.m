// On-screen touch controls for the iPhone build: two virtual sticks (move / camera) and the Switch buttons the game
// needs (A B X Y, L R ZL ZR, + -, d-pad). The state goes to the runtime through runtime_touch_pad_set(), which merges it
// with any physical controller (runtime/gamepad.m).
#import <UIKit/UIKit.h>
#include "runtime.h"
#include <math.h>

typedef NS_ENUM(NSInteger, PadRole) {
    RoleNone = 0, RoleStickL, RoleStickR,
    RoleA, RoleB, RoleX, RoleY, RoleL, RoleR, RoleZL, RoleZR, RolePlus, RoleMinus,
    RoleUp, RoleDown, RoleLeft, RoleRight
};

@interface TOTKPadView : UIView
@end

@implementation TOTKPadView {
    // per-touch role and stick origin (in this view's coordinates)
    NSMutableDictionary<NSValue *, NSNumber *> *_roles;
    CGPoint _originL, _originR, _curL, _curR;
    CGFloat _radius;
    UIView *_knobL, *_knobR, *_baseL, *_baseR;
    UILabel *_fpsHint;
}
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.multipleTouchEnabled = YES;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _roles = [NSMutableDictionary dictionary];
    _radius = 70;
    _baseL = [self circleWithTitle:nil];
    _baseR = [self circleWithTitle:nil];
    _knobL = [self knob];
    _knobR = [self knob];
    [self addSubview:_baseL]; [self addSubview:_knobL];
    [self addSubview:_baseR]; [self addSubview:_knobR];
    for (NSNumber *r in @[@(RoleA), @(RoleB), @(RoleX), @(RoleY), @(RoleL), @(RoleR), @(RoleZL), @(RoleZR),
                          @(RolePlus), @(RoleMinus), @(RoleUp), @(RoleDown), @(RoleLeft), @(RoleRight)]) {
        NSString *t = [self titleForRole:r.integerValue];
        UILabel *b = [self circleWithTitle:t];
        b.tag = 100 + r.integerValue;
        [self addSubview:b];
    }
    _fpsHint = nil;
    return self;
}

- (UIView *)knob {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 54, 54)];
    v.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.22];
    v.layer.cornerRadius = 27;
    v.layer.borderWidth = 1.5;
    v.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.5].CGColor;
    v.userInteractionEnabled = NO;
    v.hidden = YES;
    return v;
}
- (UIView *)circleWithTitle:(NSString *)title {
    UIView *v = [[UIView alloc] initWithFrame:CGRectZero];
    v.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.35];
    v.layer.borderWidth = 1.5;
    v.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.45].CGColor;
    v.userInteractionEnabled = NO;
    if (title) {
        UILabel *l = [[UILabel alloc] initWithFrame:v.bounds];
        l.text = title; l.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
        l.font = [UIFont boldSystemFontOfSize:15];
        l.textAlignment = NSTextAlignmentCenter;
        l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        l.tag = 7; [v addSubview:l];
    }
    return v;
}
- (NSString *)titleForRole:(PadRole)r {
    switch (r) {
        case RoleA: return @"A"; case RoleB: return @"B"; case RoleX: return @"X"; case RoleY: return @"Y";
        case RoleL: return @"L"; case RoleR: return @"R"; case RoleZL: return @"ZL"; case RoleZR: return @"ZR";
        case RolePlus: return @"+"; case RoleMinus: return @"−";
        case RoleUp: return @"▲"; case RoleDown: return @"▼"; case RoleLeft: return @"◀"; case RoleRight: return @"▶";
        default: return nil;
    }
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    CGFloat r = MIN(38.0, h * 0.075);
    _radius = MIN(86.0, h * 0.17);
    CGFloat btn = r * 2;
    // buttons: A/B/X/Y diamond at the right, L/R/ZL/ZR at the top, +/− at top centre, d-pad bottom left
    struct { PadRole role; CGFloat x, y; } pos[] = {
        {RoleA, w - 2.9 * r, h - 2.6 * r}, {RoleB, w - 4.9 * r, h - 2.0 * r},
        {RoleX, w - 4.9 * r, h - 4.0 * r}, {RoleY, w - 6.9 * r, h - 2.6 * r},
        {RoleZR, w - 2.2 * r, 1.7 * r}, {RoleR, w - 4.2 * r, 1.7 * r},
        {RoleZL, 2.2 * r, 1.7 * r}, {RoleL, 4.2 * r, 1.7 * r},
        {RolePlus, w * 0.5 + 2.6 * r, 1.6 * r}, {RoleMinus, w * 0.5 - 2.6 * r, 1.6 * r},
        {RoleUp, 3.4 * r, h - 5.0 * r}, {RoleDown, 3.4 * r, h - 1.9 * r},
        {RoleLeft, 1.5 * r, h - 3.4 * r}, {RoleRight, 5.3 * r, h - 3.4 * r},
    };
    for (unsigned i = 0; i < sizeof pos / sizeof *pos; i++) {
        UIView *b = [self viewWithTag:100 + pos[i].role];
        b.frame = CGRectMake(pos[i].x - r, pos[i].y - r, btn, btn);
        b.layer.cornerRadius = r;
    }
    _baseL.bounds = CGRectMake(0, 0, _radius * 2, _radius * 2); _baseL.layer.cornerRadius = _radius;
    _baseR.bounds = _baseL.bounds; _baseR.layer.cornerRadius = _radius;
    [self layoutSticks];
}
- (void)layoutSticks {
    CGPoint bl = _originL, br = _originR;
    _baseL.center = bl; _baseR.center = br;
    _knobL.center = _curL; _knobR.center = _curR;
    _baseL.hidden = _baseR.hidden = _knobL.hidden = _knobR.hidden = (_roles.count == 0);
}

// --- hit testing -----------------------------------------------------------
- (PadRole)roleAt:(CGPoint)p {
    for (NSNumber *r in @[@(RoleA), @(RoleB), @(RoleX), @(RoleY), @(RoleL), @(RoleR), @(RoleZL), @(RoleZR),
                          @(RolePlus), @(RoleMinus), @(RoleUp), @(RoleDown), @(RoleLeft), @(RoleRight)]) {
        UIView *v = [self viewWithTag:100 + r.integerValue];
        if (CGRectContainsPoint(v.frame, p)) return (PadRole)r.integerValue;
    }
    CGFloat w = self.bounds.size.width;
    if (p.x < w * 0.45) return RoleStickL;
    if (p.x > w * 0.55) return RoleStickR;
    return RoleNone;
}
- (void)pushState {
    RuntimeGamepadState s = {0};
    s.connected = 1;
    uint64_t map[] = {0, 0, 0, 0, 0, 0};   // per role below
    for (NSNumber *n in _roles.allValues) {
        switch ((PadRole)n.integerValue) {
            case RoleA: s.buttons |= 1ULL << 0; break;
            case RoleB: s.buttons |= 1ULL << 1; break;
            case RoleX: s.buttons |= 1ULL << 2; break;
            case RoleY: s.buttons |= 1ULL << 3; break;
            case RoleL: s.buttons |= 1ULL << 6; break;
            case RoleR: s.buttons |= 1ULL << 7; break;
            case RoleZL: s.buttons |= 1ULL << 8; break;
            case RoleZR: s.buttons |= 1ULL << 9; break;
            case RolePlus: s.buttons |= 1ULL << 10; break;
            case RoleMinus: s.buttons |= 1ULL << 11; break;
            case RoleLeft: s.buttons |= 1ULL << 12; break;
            case RoleUp: s.buttons |= 1ULL << 13; break;
            case RoleRight: s.buttons |= 1ULL << 14; break;
            case RoleDown: s.buttons |= 1ULL << 15; break;
            default: break;
        }
    }
    (void)map;
    CGFloat dx = _curL.x - _originL.x, dy = _curL.y - _originL.y;
    CGFloat len = hypot(dx, dy);
    if (len > _radius) { dx = dx / len * _radius; dy = dy / len * _radius; len = _radius; }
    if (len > 6) { s.lx = (int32_t)(dx / _radius * 32767); s.ly = (int32_t)(-dy / _radius * 32767); }
    dx = _curR.x - _originR.x; dy = _curR.y - _originR.y;
    len = hypot(dx, dy);
    if (len > _radius) { dx = dx / len * _radius; dy = dy / len * _radius; len = _radius; }
    if (len > 6) { s.rx = (int32_t)(dx / _radius * 32767); s.ry = (int32_t)(-dy / _radius * 32767); }
    runtime_touch_pad_set(&s);
    [self layoutSticks];
}
- (void)touch:(UITouch *)t began:(BOOL)began {
    CGPoint p = [t locationInView:self];
    NSValue *key = [NSValue valueWithNonretainedObject:t];
    if (began) {
        PadRole r = [self roleAt:p];
        if (r == RoleNone) return;
        _roles[key] = @(r);
        if (r == RoleStickL) { _originL = _curL = p; }
        else if (r == RoleStickR) { _originR = _curR = p; }
        [self layoutSticks];
    } else if (_roles[key]) {
        _roles[key] = nil;
    }
    [self pushState];
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e { for (UITouch *t in touches) [self touch:t began:YES]; }
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e {
    for (UITouch *t in touches) {
        NSValue *key = [NSValue valueWithNonretainedObject:t];
        NSNumber *role = _roles[key];
        if (!role) continue;
        CGPoint p = [t locationInView:self];
        if (role.integerValue == RoleStickL) _curL = p;
        else if (role.integerValue == RoleStickR) _curR = p;
    }
    [self pushState];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e { for (UITouch *t in touches) [self touch:t began:NO]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e { for (UITouch *t in touches) [self touch:t began:NO]; }
@end

void runtime_touch_controls_install(UIView *host) {
    if (getenv("TOTK_TOUCH_UI") && !atoi(getenv("TOTK_TOUCH_UI"))) return;
    TOTKPadView *pad = [[TOTKPadView alloc] initWithFrame:host.bounds];
    pad.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [host addSubview:pad];
    fprintf(stderr, "[totk-ios] touch controls installed (%.0fx%.0f)\n", host.bounds.size.width, host.bounds.size.height);
}
