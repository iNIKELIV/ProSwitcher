#import "PSWViewController.h"

#import <QuartzCore/QuartzCore.h>
#import <SpringBoard/SpringBoard.h>
#import <CaptainHook/CaptainHook.h>

#include <dlfcn.h>

#import "PSWDisplayStacks.h"
#import "PSWResources.h"
#import "SpringBoard+Backgrounder.h"

// Using Zero-link until we get a simulator build for libactivator :(
CHDeclareClass(LAActivator);

CHDeclareClass(SBStatusBarController);
CHDeclareClass(SBApplication)
CHDeclareClass(SpringBoard);
CHDeclareClass(SBIconListPageControl);
CHDeclareClass(SBUIController);
CHDeclareClass(SBApplicationController);
CHDeclareClass(SBIconModel);
CHDeclareClass(SBIconController);

static PSWViewController *mainController;
static NSInteger suppressIconScatter;

#define SBActive ([SBWActiveDisplayStack topApplication] == nil)
#define SBSharedInstance ((SpringBoard *) [UIApplication sharedApplication])

#define PSWPreferencesFilePath [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/com.collab.proswitcher.plist"]
#define PSWPreferencesChangedNotification "com.collab.proswitcher.preferencechanged"

#define idForKeyWithDefault(dict, key, default)	 ([(dict) objectForKey:(key)]?:(default))
#define floatForKeyWithDefault(dict, key, default)   ({ id _result = [(dict) objectForKey:(key)]; (_result)?[_result floatValue]:(default); })
#define NSIntegerForKeyWithDefault(dict, key, default) (NSInteger)({ id _result = [(dict) objectForKey:(key)]; (_result)?[_result integerValue]:(default); })
#define BOOLForKeyWithDefault(dict, key, default)    (BOOL)({ id _result = [(dict) objectForKey:(key)]; (_result)?[_result boolValue]:(default); })

@implementation PSWViewController

#define GetPreference(name, type) type ## ForKeyWithDefault(preferences, @#name, (name))

// Defaults
#define PSWShowDock             YES
#define PSWAnimateActive        YES
#define PSWDimBackground        YES
#define PSWShowPageControl      YES
#define PSWBackgroundStyle      0
#define PSWSwipeToClose         YES
#define PSWShowApplicationTitle YES
#define PSWShowCloseButton      YES
#define PSWShowEmptyText        YES
#define PSWRoundedCornerRadius  0.0f
#define PSWTapsToActivate       2
#define PSWSnapshotInset        40.0f
#define PSWUnfocusedAlpha       1.0f
#define PSWShowDefaultApps      YES
#define PSWDefaultApps          [NSArray arrayWithObjects:@"com.apple.mobileipod-MediaPlayer", @"com.apple.mobilephone", @"com.apple.mobilemail", @"com.apple.mobilesafari", nil]

+ (PSWViewController *)sharedInstance
{
	if (!mainController)
		mainController = [[PSWViewController alloc] init];
	return mainController;
}

- (void)didFinishDeactivate
{
	[[UIApplication sharedApplication] setStatusBarStyle:formerStatusBarStyle animated:NO];
	[[self view] removeFromSuperview];
	isAnimating = NO;
}

- (void)didFinishActivate
{
	isAnimating = NO;
}

- (BOOL)isActive
{
	return isActive;
}

- (void)setActive:(BOOL)active animated:(BOOL)animated
{
	if (active) {
		// Find appropriate superview and add as subview
		UIView *view = [self view];
		UIView *buttonBar = [CHSharedInstance(SBIconModel) buttonBar];
		UIView *buttonBarParent = [buttonBar superview];
		UIView *superview = [buttonBarParent superview];
		[view removeFromSuperview];
		// Reparent always; even when already active
		if (GetPreference(PSWShowDock, BOOL))
			[superview insertSubview:view belowSubview:buttonBarParent];
		else
			[superview insertSubview:view aboveSubview:buttonBarParent];
		if (!isActive) {
			UIApplication *app = [UIApplication sharedApplication];
			formerStatusBarStyle = [app statusBarStyle];
			[app setStatusBarStyle:UIStatusBarStyleDefault animated:NO];
			isActive = YES;

			snapshotPageView.focusedApplication = focusedApplication;
			UIWindow *rootWindow = [CHSharedInstance(SBUIController) window];
			[rootWindow endEditing:YES]; // force keyboard hide in spotlight
			SBIconListPageControl *pageControl = CHIvar(CHSharedInstance(SBIconController), _pageControl, SBIconListPageControl *);
			if (animated) {
				view.alpha = 0.0f;
				CALayer *layer = [snapshotPageView.scrollView layer];
				[layer setTransform:CATransform3DMakeScale(2.0f, 2.0f, 1.0f)];
				[UIView beginAnimations:nil context:nil];
				[UIView setAnimationDuration:0.5f];
				[UIView setAnimationDelegate:self];
				[UIView setAnimationDidStopSelector:@selector(didFinishActivate)];
				[layer setTransform:CATransform3DIdentity];
				[view setAlpha:1.0f];
				if (GetPreference(PSWShowPageControl, BOOL))
					[pageControl setAlpha:0.0f];
				[UIView commitAnimations];
				isAnimating = YES;
			} else {
				if (GetPreference(PSWShowPageControl, BOOL))
					[pageControl setAlpha:0.0f];
			}
		}
	} else {
		if (!isActive)
			return;
		isActive = NO;
		
		[focusedApplication release];
		focusedApplication = [snapshotPageView.focusedApplication retain];
		SBIconListPageControl *pageControl = CHIvar(CHSharedInstance(SBIconController), _pageControl, SBIconListPageControl *);
		UIView *view = [self view];
		if (animated) {
			CALayer *layer = [snapshotPageView.scrollView layer];
			[layer setTransform:CATransform3DIdentity];
			[UIView beginAnimations:nil context:nil];
			[UIView setAnimationDuration:0.5f];
			[UIView setAnimationDelegate:self];
			[UIView setAnimationDidStopSelector:@selector(didFinishDeactivate)];
			[layer setTransform:CATransform3DMakeScale(2.0f, 2.0f, 1.0f)];
			[view setAlpha:0.0f];
			if (GetPreference(PSWShowPageControl, BOOL))
				[pageControl setAlpha:1.0f];
			[UIView commitAnimations];
			isAnimating = YES;
		} else {
			[[UIApplication sharedApplication] setStatusBarStyle:formerStatusBarStyle animated:NO];
			if (GetPreference(PSWShowPageControl, BOOL))
				[pageControl setAlpha:1.0f];
			[view removeFromSuperview];
		}
	}
}

- (void)setActive:(BOOL)active
{
	[self setActive:active animated:GetPreference(PSWAnimateActive, BOOL)];
}

- (void)activator:(LAActivator *)activator receiveEvent:(LAEvent *)event
{
	if ([self isAnimating])
		return;
	
	if (SBActive) {
		BOOL newActive = ![self isActive];
		[self setActive:newActive];
		if (newActive)
			[event setHandled:YES];
	} else {
		SBApplication *activeApp = [SBWActiveDisplayStack topApplication];
		NSString *activeDisplayIdentifier = [activeApp displayIdentifier];
		
		// background running app
		if ([SBSharedInstance respondsToSelector:@selector(setBackgroundingEnabled:forDisplayIdentifier:)])
			[SBSharedInstance setBackgroundingEnabled:YES forDisplayIdentifier:activeDisplayIdentifier];
		[activeApp setDeactivationSetting:0x2 flag:YES]; // animate
		//[activeApp setDeactivationSetting:0x8 value:[NSNumber numberWithDouble:1]]; // disable animations
		
		// Deactivate by moving from active stack to suspending stack
		[SBWActiveDisplayStack popDisplay:activeApp];
		[SBWSuspendingDisplayStack pushDisplay:activeApp];
		
		// Show ProSwitcher
		[self setActive:YES animated:NO];
		[snapshotPageView setFocusedApplication:[[PSWApplicationController sharedInstance] applicationWithDisplayIdentifier:activeDisplayIdentifier] animated:NO];
		
		[event setHandled:YES];
	}	
}

- (void)activator:(LAActivator *)activator abortEvent:(LAEvent *)event
{
	[self setActive:NO];
}

- (BOOL)isAnimating
{
	return isAnimating;
}

- (id)init
{
	if ((self = [super init])) {
		preferences = [[NSDictionary alloc] initWithContentsOfFile:PSWPreferencesFilePath];
	}	
	return self;
}

- (void)dealloc 
{
	[preferences release];
	[focusedApplication release];
	[snapshotPageView release];
    [super dealloc];
}

- (void)_applyPreferences
{
	self.view.backgroundColor = GetPreference(PSWDimBackground, BOOL) ? [UIColor colorWithRed:0.0 green:0.0 blue:0.0 alpha:0.8]:[UIColor clearColor];
	
	SBIconListPageControl *pageControl = CHIvar(CHSharedInstance(SBIconController), _pageControl, SBIconListPageControl *);
	if (GetPreference(PSWShowPageControl, BOOL))
		[pageControl setAlpha:0.0f];

	CGRect frame;
	frame.origin.x = 0.0f;
	frame.origin.y = [[CHClass(SBStatusBarController) sharedStatusBarController] useDoubleHeightSize]?40.0f:20.0f;
	frame.size.width = 320.0f;
	frame.size.height = (GetPreference(PSWShowDock, BOOL) ? 390.0f : 480.0f) - frame.origin.y;
	[snapshotPageView setFrame:frame];
	[snapshotPageView setBackgroundColor:[UIColor clearColor]];
	
	if (GetPreference(PSWBackgroundStyle, NSInteger) == 1)
		[[snapshotPageView layer] setContents:(id)[PSWGetCachedSpringBoardResource(@"ProSwitcherBackground") CGImage]];
	else
		[[snapshotPageView layer] setContents:nil];
	
	snapshotPageView.allowsSwipeToClose  = GetPreference(PSWSwipeToClose, BOOL);
	snapshotPageView.showsTitles         = GetPreference(PSWShowApplicationTitle, BOOL);
	snapshotPageView.showsCloseButtons   = GetPreference(PSWShowCloseButton, BOOL);
	snapshotPageView.emptyText           = GetPreference(PSWShowEmptyText, BOOL) ? @"No Apps Running":nil;
	snapshotPageView.roundedCornerRadius = GetPreference(PSWRoundedCornerRadius, float);
	snapshotPageView.tapsToActivate      = GetPreference(PSWTapsToActivate, NSInteger);
	snapshotPageView.snapshotInset       = GetPreference(PSWSnapshotInset, float);
	snapshotPageView.unfocusedAlpha      = GetPreference(PSWUnfocusedAlpha, float);
	snapshotPageView.showsPageControl    = GetPreference(PSWShowPageControl, BOOL);
	snapshotPageView.ignoredDisplayIdentifiers = GetPreference(PSWShowDefaultApps, BOOL)?nil:GetPreference(PSWDefaultApps, id);
}

- (void)_reloadPreferences
{
	[preferences release];
	preferences = [[NSDictionary alloc] initWithContentsOfFile:PSWPreferencesFilePath];
	[self _applyPreferences];
}

- (void)loadView 
{
	UIView *view = [[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 320.0f, 480.0f)];
	
	snapshotPageView = [[PSWSnapshotPageView alloc] initWithFrame:CGRectZero applicationController:[PSWApplicationController sharedInstance]];
	[snapshotPageView setDelegate:self];
	[view addSubview:snapshotPageView];
	
	[self setView:view];
	[self _applyPreferences];
}

- (void)viewDidUnload
{
	[snapshotPageView removeFromSuperview];
	[snapshotPageView release];
	snapshotPageView = nil;
	[super viewDidUnload];
}

- (void)didReceiveMemoryWarning
{
	[super didReceiveMemoryWarning];
	[[PSWApplicationController sharedInstance] writeSnapshotsToDisk];
	PSWClearResourceCache();
}

- (void)snapshotPageView:(PSWSnapshotPageView *)snapshotPageView didSelectApplication:(PSWApplication *)application
{
	suppressIconScatter++;
	[application activate];
	suppressIconScatter--;
}

- (void)snapshotPageView:(PSWSnapshotPageView *)snapshotPageView didCloseApplication:(PSWApplication *)application
{
	[application exit];
	UIView *view = [self view];
	[view removeFromSuperview];
	UIView *buttonBar = [CHSharedInstance(SBIconModel) buttonBar];
	UIView *buttonBarParent = [buttonBar superview];
	UIView *superview = [buttonBarParent superview];
	if (GetPreference(PSWShowDock, BOOL))
		[superview insertSubview:view belowSubview:buttonBarParent];
	else
		[superview insertSubview:view aboveSubview:buttonBarParent];	
}

- (void)snapshotPageViewShouldExit:(PSWSnapshotPageView *)snapshotPageView
{
	[self setActive:NO];
}

@end

#pragma mark SBApplication

CHMethod0(void, SBApplication, activate)
{
	[[PSWViewController sharedInstance] setActive:NO];
	CHSuper0(SBApplication, activate);
}

#pragma mark SBUIController

CHMethod3(void, SBUIController, animateApplicationActivation, SBApplication *, application, animateDefaultImage, BOOL, animateDefaultImage, scatterIcons, BOOL, scatterIcons)
{
	CHSuper3(SBUIController, animateApplicationActivation, application, animateDefaultImage, animateDefaultImage, scatterIcons, scatterIcons && suppressIconScatter == 0);
}

#pragma mark SpringBoard

static BOOL shouldSuppressIconListScroll;

CHMethod0(void, SpringBoard, _handleMenuButtonEvent)
{
	PSWViewController *vc = [PSWViewController sharedInstance];
	if ([vc isActive]) {
		// Deactivate and suppress SpringBoard list scrolling
		[vc setActive:NO];
		shouldSuppressIconListScroll = YES;
		CHSuper0(SpringBoard, _handleMenuButtonEvent);
		shouldSuppressIconListScroll = NO;
	} else {
		// Do nothing
		CHSuper0(SpringBoard, _handleMenuButtonEvent);
	}
}

#pragma mark SBIconController

CHMethod2(void, SBIconController, scrollToIconListAtIndex, NSInteger, index, animate, BOOL, animate)
{
	if (!shouldSuppressIconListScroll)
		CHSuper2(SBIconController, scrollToIconListAtIndex, index, animate, animate);
}

CHMethod1(void, SBIconController, setIsEditing, BOOL, isEditing)
{
	// Disable OverBoard when editing
	if (isEditing)
		[[PSWViewController sharedInstance] setActive:NO];
	CHSuper1(SBIconController, setIsEditing, isEditing);
}

#pragma mark Preference Changed Notification

static void PreferenceChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo)
{
	[[PSWViewController sharedInstance] _reloadPreferences];
}

/* debug for simulator since libactivator isn't there yet
CHMethod0(BOOL, SpringBoard, allowMenuDoubleTap) { return YES; }
CHMethod0(void, SpringBoard, handleMenuDoubleTap) { [[PSWViewController sharedInstance] activator:nil receiveEvent:nil]; }
*/

CHConstructor
{
	CHAutoreleasePoolForScope();
	CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, PreferenceChangedCallback, CFSTR(PSWPreferencesChangedNotification), NULL, CFNotificationSuspensionBehaviorCoalesce);
	CHLoadLateClass(SBStatusBarController);
	CHLoadLateClass(SBApplication);
	CHHook0(SBApplication, activate);
	CHLoadLateClass(SBIconListPageControl);
	CHLoadLateClass(SBUIController);
	CHHook3(SBUIController, animateApplicationActivation, animateDefaultImage, scatterIcons);
	CHLoadLateClass(SBApplicationController);
	CHLoadLateClass(SBIconModel);
	CHLoadLateClass(SpringBoard);
	CHHook0(SpringBoard, _handleMenuButtonEvent);
	CHLoadLateClass(SBIconController);
	CHHook2(SBIconController, scrollToIconListAtIndex, animate);
	CHHook1(SBIconController, setIsEditing);
	
	/* debug for simulator since libactivator isn't there yet
	CHHook0(SpringBoard, allowMenuDoubleTap);
	CHHook0(SpringBoard, handleMenuDoubleTap);
	*/
	
	// Using late-binding until we get a simulator build for libactivator :(
	dlopen("/usr/lib/libactivator.dylib", RTLD_LAZY);
	CHLoadLateClass(LAActivator);
	[CHSharedInstance(LAActivator) registerListener:[PSWViewController sharedInstance] forName:@"com.collab.proswitcher"];
}
