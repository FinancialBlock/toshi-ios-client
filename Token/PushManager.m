//
//  PushManager.m
//  Signal
//
//  Created by Frederic Jacobs on 31/07/14.
//  Copyright (c) 2014 Open Whisper Systems. All rights reserved.
//

#import "PushManager.h"
#import "AppDelegate.h"
#import "NotificationTracker.h"
#import "ContactsManager.h"
//#import "PropertyListPreferences.h"
//#import "RPServerRequestsManager.h"
#import <CocoaLumberjack/CocoaLumberjack.h>
#import <CocoaLumberjack/DDLogMacros.h>
#import <SignalServiceKit/NSDate+millisecondTimeStamp.h>
#import <SignalServiceKit/TSThread.h>
#import <SignalServiceKit/TSStorageManager.h>
#import <SignalServiceKit/TSOutgoingMessage.h>
#import <SignalServiceKit/TSSocketManager.h>
#import <SignalServiceKit/OWSMessageSender.h>

static const NSUInteger ddLogLevel = DDLogLevelAll;

#define pushManagerDomain @"org.whispersystems.pushmanager"

@interface NSData (ows_StripToken)

- (NSString *)ows_tripToken;

@end

@implementation NSData (ows_StripToken)

- (NSString *)ows_tripToken {
    return [[[NSString stringWithFormat:@"%@", self]
             stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"<>"]]
            stringByReplacingOccurrencesOfString:@" "
            withString:@""];
}

@end

@interface PushManager ()

@property TOCFutureSource *registerWithServerFutureSource;
@property UIAlertView *missingPermissionsAlertView;
@property (nonatomic, strong) NotificationTracker *notificationTracker;
@property UILocalNotification *lastCallNotification;
@property (nonatomic, retain) NSMutableArray *currentNotifications;
@property (nonatomic) UIBackgroundTaskIdentifier callBackgroundTask;
@property (nonatomic, readonly) ContactsManager *contactsManager;
@property (nonatomic, readonly) OWSMessageSender *messageSender;

@end

@implementation PushManager

+ (instancetype)sharedManager {
    static PushManager *sharedManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedManager = [[self alloc] initDefault];
    });
    return sharedManager;
}

- (instancetype)initDefault
{
    AppDelegate *appDelegate = (AppDelegate *)UIApplication.sharedApplication.delegate;

    return [self initWithContactsManager:appDelegate.contactsManager
                     notificationTracker:[NotificationTracker notificationTracker]
                          networkManager:appDelegate.networkManager
                          storageManager:[TSStorageManager sharedManager]
                         contactsUpdater:appDelegate.contactsUpdater];
}

- (instancetype)initWithContactsManager:(ContactsManager *)contactsManager
                    notificationTracker:(NotificationTracker *)notificationTracker
                         networkManager:(TSNetworkManager *)networkManager
                         storageManager:(TSStorageManager *)storageManager
                        contactsUpdater:(ContactsUpdater *)contactsUpdater
{
    self = [super init];
    if (!self) {
        return self;
    }

    _contactsManager = contactsManager;
    _notificationTracker = notificationTracker;
    _messageSender = [[OWSMessageSender alloc] initWithNetworkManager:networkManager
                                                       storageManager:storageManager
                                                      contactsManager:contactsManager
                                                      contactsUpdater:contactsUpdater];

    _missingPermissionsAlertView = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"ACTION_REQUIRED_TITLE", @"")
                                                              message:NSLocalizedString(@"PUSH_SETTINGS_MESSAGE", @"")
                                                             delegate:nil
                                                    cancelButtonTitle:NSLocalizedString(@"OK", @"")
                                                    otherButtonTitles:nil, nil];
    _callBackgroundTask = UIBackgroundTaskInvalid;
    _currentNotifications = [NSMutableArray array];

    return self;
}

#pragma mark Manage Incoming Push

- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo {
    if (![self applicationIsActive]) {
        [TSSocketManager becomeActiveFromBackgroundExpectMessage:YES];
    }
}

/**
 *  This code should in principle never be called. The only cases where it would be called are with the old-style
 * "content-available:1" pushes if there is no "voip" token registered
 *
 */

- (void)application:(UIApplication *)application
    didReceiveRemoteNotification:(NSDictionary *)userInfo
          fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {
    if ([self isRedPhonePush:userInfo]) {
        [self application:application didReceiveRemoteNotification:userInfo];
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      completionHandler(UIBackgroundFetchResultNewData);
    });
}

- (void)application:(UIApplication *)application didReceiveLocalNotification:(UILocalNotification *)notification {
    NSString *threadId = notification.userInfo[Signal_Thread_UserInfo_Key];
    if (threadId && [TSThread fetchObjectWithUniqueID:threadId]) {
        // TODO: present current thread?
    }
}

- (void)application:(UIApplication *)application handleActionWithIdentifier:(NSString *)identifier forLocalNotification:(UILocalNotification *)notification completionHandler:(void (^)())completionHandler {
    [self application:application handleActionWithIdentifier:identifier forLocalNotification:notification withResponseInfo:@{} completionHandler:completionHandler];
}

- (void)application:(UIApplication *)application handleActionWithIdentifier:(NSString *)identifier forLocalNotification:(UILocalNotification *)notification withResponseInfo:(NSDictionary *)responseInfo completionHandler:(void (^)())completionHandler
{
    if ([identifier isEqualToString:Signal_Message_Reply_Identifier]) {
        NSString *threadId = notification.userInfo[Signal_Thread_UserInfo_Key];

        if (threadId) {
            TSThread *thread = [TSThread fetchObjectWithUniqueID:threadId];
            TSOutgoingMessage *message = [[TSOutgoingMessage alloc] initWithTimestamp:[NSDate ows_millisecondTimeStamp] inThread:thread messageBody:responseInfo[UIUserNotificationActionResponseTypedTextKey]];

            [self.messageSender sendMessage:message success:^{

                    [self markAllInThreadAsRead:notification.userInfo completionHandler:completionHandler];
                // TODO: update tableview
//                    [[[[Environment getCurrent] signalsViewController] tableView] reloadData];

                } failure:^(NSError *error) {
                    // TODO Surface the specific error in the notification?
                    DDLogError(@"Message send failed with error: %@", error);

                    UILocalNotification *failedSendNotif = [[UILocalNotification alloc] init];
                    failedSendNotif.alertBody =
                        [NSString stringWithFormat:NSLocalizedString(@"NOTIFICATION_SEND_FAILED", nil), [thread name]];
                    failedSendNotif.userInfo = @{ Signal_Thread_UserInfo_Key : thread.uniqueId };
                    [self presentNotification:failedSendNotif];
                    completionHandler();
                }];
        }
    } else if ([identifier isEqualToString:Signal_Message_MarkAsRead_Identifier]) {
        [self markAllInThreadAsRead:notification.userInfo completionHandler:completionHandler];
    } else {
        NSString *threadId = notification.userInfo[Signal_Thread_UserInfo_Key];

        // TODO: display thread
//        [Environment messageThreadId:threadId];
        completionHandler();
    }
}

- (void)markAllInThreadAsRead:(NSDictionary *)userInfo completionHandler:(void (^)())completionHandler {
    NSString *threadId = userInfo[Signal_Thread_UserInfo_Key];

    TSThread *thread = [TSThread fetchObjectWithUniqueID:threadId];
    [[TSStorageManager sharedManager]
            .dbConnection asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction *_Nonnull transaction) {
      [thread markAllAsReadWithTransaction:transaction];
    }
        completionBlock:^{
            // TODO: update inbox count label for current thrtead
//          [[[Environment getCurrent] signalsViewController] updateInboxCountLabel];
          [self cancelNotificationsWithThreadId:threadId];

          completionHandler();
        }];
}

- (BOOL)isRedPhonePush:(NSDictionary *)pushDict {
    NSDictionary *aps  = pushDict[@"aps"];
    NSString *category = aps[@"category"];

    if ([category isEqualToString:Signal_Call_Category]) {
        return YES;
    } else {
        return NO;
    }
}

#pragma mark PushKit

- (void)pushRegistry:(PKPushRegistry *)registry
    didUpdatePushCredentials:(PKPushCredentials *)credentials
                     forType:(NSString *)type {
    [[PushManager sharedManager].pushKitNotificationFutureSource trySetResult:[credentials.token ows_tripToken]];
}

- (void)pushRegistry:(PKPushRegistry *)registry
    didReceiveIncomingPushWithPayload:(PKPushPayload *)payload
                              forType:(NSString *)type {
    [self application:[UIApplication sharedApplication] didReceiveRemoteNotification:payload.dictionaryPayload];
}

- (TOCFuture *)registerPushKitNotificationFuture {
//    if ([self supportsVOIPPush]) {
//        self.pushKitNotificationFutureSource = [TOCFutureSource new];
//        PKPushRegistry *voipRegistry         = [[PKPushRegistry alloc] initWithQueue:dispatch_get_main_queue()];
//        voipRegistry.delegate                = self;
//        voipRegistry.desiredPushTypes        = [NSSet setWithObject:PKPushTypeVoIP];
//        return self.pushKitNotificationFutureSource.future;
//    } else {
        TOCFutureSource *futureSource = [TOCFutureSource new];
        [futureSource trySetResult:nil];

        return futureSource.future;
//    }
}

#pragma mark Register device for Push Notification locally

- (TOCFuture *)registerPushNotificationFuture {
    self.pushNotificationFutureSource = [TOCFutureSource new];
    [UIApplication.sharedApplication registerForRemoteNotifications];
    return self.pushNotificationFutureSource.future;
}

- (void)requestPushTokenWithSuccess:(pushTokensSuccessBlock)success failure:(failedPushRegistrationBlock)failure {
    if (!self.wantRemoteNotifications) {
        DDLogWarn(@"%@ Using fake push tokens", self.tag);
        success(@"fakePushToken", @"fakeVoipToken");
        return;
    }

//    TOCFuture *requestPushTokenFuture = [self registerPushNotificationFuture];
//
//    [requestPushTokenFuture thenDo:^(NSData *pushTokenData) {
//      NSString *pushToken = [pushTokenData ows_tripToken];
//      TOCFuture *pushKit  = [self registerPushKitNotificationFuture];
//
//      [pushKit thenDo:^(NSString *voipToken) {
//        success(pushToken, voipToken);
//      }];
//
//      [pushKit catchDo:^(NSError *error) {
//        failure(error);
//      }];
//    }];
//
//    [requestPushTokenFuture catchDo:^(NSError *error) {
//      failure(error);
//    }];
}

- (UIUserNotificationCategory *)fullNewMessageNotificationCategory {
    UIMutableUserNotificationAction *action_markRead = [UIMutableUserNotificationAction new];
    action_markRead.identifier                       = Signal_Message_MarkAsRead_Identifier;
    action_markRead.title                            = NSLocalizedString(@"PUSH_MANAGER_MARKREAD", nil);
    action_markRead.destructive                      = NO;
    action_markRead.authenticationRequired           = NO;
    action_markRead.activationMode                   = UIUserNotificationActivationModeBackground;

    UIMutableUserNotificationAction *action_reply = [UIMutableUserNotificationAction new];
    action_reply.identifier                       = Signal_Message_Reply_Identifier;
    action_reply.title                            = NSLocalizedString(@"PUSH_MANAGER_REPLY", @"");
    action_reply.destructive                      = NO;
    action_reply.authenticationRequired           = NO; // Since YES is broken in iOS 9 GM

    action_reply.behavior       = UIUserNotificationActionBehaviorTextInput;
    action_reply.activationMode = UIUserNotificationActivationModeBackground;

    UIMutableUserNotificationCategory *messageCategory = [UIMutableUserNotificationCategory new];
    messageCategory.identifier                         = Signal_Full_New_Message_Category;
    [messageCategory setActions:@[ action_markRead, action_reply ] forContext:UIUserNotificationActionContextMinimal];
    [messageCategory setActions:@[] forContext:UIUserNotificationActionContextDefault];

    return messageCategory;
}

- (UIUserNotificationCategory *)userNotificationsCallCategory {
    UIMutableUserNotificationAction *action_accept = [UIMutableUserNotificationAction new];
    action_accept.identifier                       = Signal_Call_Accept_Identifier;
    action_accept.title                            = NSLocalizedString(@"ANSWER_CALL_BUTTON_TITLE", @"");
    action_accept.activationMode                   = UIUserNotificationActivationModeForeground;
    action_accept.destructive                      = NO;
    action_accept.authenticationRequired           = NO;

    UIMutableUserNotificationAction *action_decline = [UIMutableUserNotificationAction new];
    action_decline.identifier                       = Signal_Call_Decline_Identifier;
    action_decline.title                            = NSLocalizedString(@"REJECT_CALL_BUTTON_TITLE", @"");
    action_decline.activationMode                   = UIUserNotificationActivationModeBackground;
    action_decline.destructive                      = NO;
    action_decline.authenticationRequired           = NO;

    UIMutableUserNotificationCategory *callCategory = [UIMutableUserNotificationCategory new];
    callCategory.identifier                         = Signal_Call_Category;
    [callCategory setActions:@[ action_accept, action_decline ] forContext:UIUserNotificationActionContextMinimal];
    [callCategory setActions:@[ action_accept, action_decline ] forContext:UIUserNotificationActionContextDefault];

    return callCategory;
}

- (UIUserNotificationCategory *)userNotificationsCallBackCategory {
    UIMutableUserNotificationAction *action_accept = [UIMutableUserNotificationAction new];
    action_accept.identifier                       = Signal_CallBack_Identifier;
    action_accept.title                            = NSLocalizedString(@"CALLBACK_BUTTON_TITLE", @"");
    action_accept.activationMode                   = UIUserNotificationActivationModeForeground;
    action_accept.destructive                      = NO;
    action_accept.authenticationRequired           = NO;

    UIMutableUserNotificationCategory *callCategory = [UIMutableUserNotificationCategory new];
    callCategory.identifier                         = Signal_CallBack_Category;
    [callCategory setActions:@[ action_accept ] forContext:UIUserNotificationActionContextMinimal];
    [callCategory setActions:@[ action_accept ] forContext:UIUserNotificationActionContextDefault];

    return callCategory;
}

- (BOOL)needToRegisterForRemoteNotifications {
    return self.wantRemoteNotifications && (!UIApplication.sharedApplication.isRegisteredForRemoteNotifications);
}

- (BOOL)wantRemoteNotifications {
#if TARGET_IPHONE_SIMULATOR
    return NO;
#else
    return YES;
#endif
}

- (int)allNotificationTypes {
    return UIUserNotificationTypeAlert | UIUserNotificationTypeSound | UIUserNotificationTypeBadge;
}

- (void)validateUserNotificationSettings
{
    UIUserNotificationSettings *settings =
        [UIUserNotificationSettings settingsForTypes:(UIUserNotificationType)[self allNotificationTypes]
                                          categories:[NSSet setWithObjects:[self userNotificationsCallCategory],
                                                            [self fullNewMessageNotificationCategory],
                                                            [self userNotificationsCallBackCategory],
                                                            nil]];

    [UIApplication.sharedApplication registerUserNotificationSettings:settings];
}

- (BOOL)applicationIsActive {
    UIApplication *app = [UIApplication sharedApplication];

    if (app.applicationState == UIApplicationStateActive) {
        return YES;
    }

    return NO;
}

- (void)presentNotification:(UILocalNotification *)notification {
    [[UIApplication sharedApplication] scheduleLocalNotification:notification];
    [self.currentNotifications addObject:notification];
}

- (void)cancelNotificationsWithThreadId:(NSString *)threadId {
    NSMutableArray *toDelete = [NSMutableArray array];
    [self.currentNotifications enumerateObjectsUsingBlock:^(UILocalNotification *notif, NSUInteger idx, BOOL *stop) {
      if ([notif.userInfo[Signal_Thread_UserInfo_Key] isEqualToString:threadId]) {
          [[UIApplication sharedApplication] cancelLocalNotification:notif];
          [toDelete addObject:notif];
      }
    }];
    [self.currentNotifications removeObjectsInArray:toDelete];
}

+ (NSString *)tag
{
    return [NSString stringWithFormat:@"[%@]", self.class];
}

- (NSString *)tag
{
    return self.class.tag;
}

@end
