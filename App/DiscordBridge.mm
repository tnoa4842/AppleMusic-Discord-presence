#import "DiscordBridge.h"
#import <Security/Security.h>

#define DISCORDPP_IMPLEMENTATION
#include "discordpp.h"

#include <memory>
#include <optional>
#include <string>
#include <cstdint>


namespace {

struct PendingPresence {
    bool valid = false;
    uint64_t version = 0;

    std::string presenceID;

    std::string title;
    std::string artist;
    std::string album;

    std::optional<std::string> songURL;
    std::optional<std::string> artworkURL;

    int64_t startTimestamp = 0;
    int64_t endTimestamp = 0;
};


static NSString * const DiscordTokenService =
    @"AppleMusicDiscordPresence.DiscordOAuth.v1";


static std::string NSStringToString(
    NSString *value
) {
    if (!value) {
        return "";
    }

    const char *utf8 =
        value.UTF8String;

    if (!utf8) {
        return "";
    }

    return std::string(utf8);
}


static NSString *StringToNSString(
    const std::string &value
) {
    NSString *result =
        [NSString stringWithUTF8String:
            value.c_str()
        ];

    return result ?: @"";
}


static std::optional<std::string>
NSStringToOptionalString(
    NSString *value
) {
    if (!value ||
        value.length == 0) {

        return std::nullopt;
    }

    return NSStringToString(
        value
    );
}


static NSString *TokenAccount(
    uint64_t applicationID
) {
    return
        [NSString stringWithFormat:
            @"%llu",
            (unsigned long long)applicationID
        ];
}


// MARK: =========================================
// MARK: Keychain
// MARK: =========================================

static NSDictionary *BaseKeychainQuery(
    uint64_t applicationID
) {
    return @{
        (__bridge id)kSecClass:
            (__bridge id)kSecClassGenericPassword,

        (__bridge id)kSecAttrService:
            DiscordTokenService,

        (__bridge id)kSecAttrAccount:
            TokenAccount(applicationID)
    };
}


static NSDictionary *LoadTokenPayload(
    uint64_t applicationID
) {
    NSMutableDictionary *query =
        [
            BaseKeychainQuery(applicationID)
            mutableCopy
        ];

    query[
        (__bridge id)kSecReturnData
    ] = @YES;

    query[
        (__bridge id)kSecMatchLimit
    ] =
        (__bridge id)kSecMatchLimitOne;

    CFTypeRef result = NULL;

    OSStatus status =
        SecItemCopyMatching(
            (__bridge CFDictionaryRef)query,
            &result
        );

    if (status != errSecSuccess ||
        result == NULL) {

        return nil;
    }

    NSData *data =
        (__bridge_transfer NSData *)result;

    if (!data) {
        return nil;
    }

    NSError *error = nil;

    id object =
        [NSJSONSerialization
            JSONObjectWithData:data
            options:0
            error:&error
        ];

    if (error ||
        ![
            object
            isKindOfClass:[NSDictionary class]
        ]) {

        return nil;
    }

    return (NSDictionary *)object;
}


static BOOL SaveTokenPayload(
    uint64_t applicationID,
    NSDictionary *payload
) {
    NSError *error = nil;

    NSData *data =
        [NSJSONSerialization
            dataWithJSONObject:payload
            options:0
            error:&error
        ];

    if (error || !data) {
        return NO;
    }

    NSDictionary *baseQuery =
        BaseKeychainQuery(applicationID);

    NSDictionary *attributes = @{
        (__bridge id)kSecValueData:
            data,

        (__bridge id)kSecAttrAccessible:
            (__bridge id)
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    };

    OSStatus status =
        SecItemUpdate(
            (__bridge CFDictionaryRef)baseQuery,
            (__bridge CFDictionaryRef)attributes
        );

    if (status == errSecItemNotFound) {

        NSMutableDictionary *newItem =
            [baseQuery mutableCopy];

        [
            newItem
            addEntriesFromDictionary:attributes
        ];

        status =
            SecItemAdd(
                (__bridge CFDictionaryRef)newItem,
                NULL
            );
    }

    return status == errSecSuccess;
}


static void DeleteTokenPayload(
    uint64_t applicationID
) {
    NSDictionary *query =
        BaseKeychainQuery(applicationID);

    SecItemDelete(
        (__bridge CFDictionaryRef)query
    );
}

} // namespace



@interface DiscordBridge ()

- (void)notifyReady:(BOOL)ready
               text:(NSString *)text;

- (void)notifyPresenceResultForID:
            (NSString *)presenceID
                              success:
            (BOOL)success;

- (void)ensureClient;

- (void)loadStoredTokensIfNeeded;

- (void)saveTokensWithAccessToken:
            (NSString *)accessToken
                    refreshToken:
            (NSString *)refreshToken
                       expiresIn:
            (int32_t)expiresIn;

- (void)clearStoredTokens;

- (BOOL)shouldRefreshToken;

- (void)applyStoredAccessTokenAndConnect;

- (void)refreshStoredToken;

- (void)scheduleRefreshRetry:
            (NSTimeInterval)delay;

- (void)beginAuthorization;

- (void)sendPendingPresenceIfPossible;

- (void)schedulePresenceRetry:
            (NSTimeInterval)delay;

@end



@implementation DiscordBridge {

    std::shared_ptr<discordpp::Client>
        _client;

    uint64_t
        _applicationID;

    uint64_t
        _tokensLoadedForApplicationID;

    BOOL
        _authorizationRunning;

    BOOL
        _tokenOperationRunning;

    BOOL
        _ready;

    std::string
        _accessToken;

    std::string
        _refreshToken;

    double
        _accessTokenExpiresAt;

    PendingPresence
        _pendingPresence;

    uint64_t
        _presenceVersion;

    BOOL
        _presenceUpdateInFlight;

    BOOL
        _presenceRetryScheduled;
}


// MARK: =========================================
// MARK: Singleton
// MARK: =========================================

+ (instancetype)shared {
    static DiscordBridge *instance =
        nil;

    static dispatch_once_t onceToken;

    dispatch_once(
        &onceToken,
        ^{
            instance =
                [[DiscordBridge alloc] init];
        }
    );

    return instance;
}


// MARK: =========================================
// MARK: Init
// MARK: =========================================

- (instancetype)init {
    self =
        [super init];

    if (self) {
        _applicationID =
            0;

        _tokensLoadedForApplicationID =
            0;

        _authorizationRunning =
            NO;

        _tokenOperationRunning =
            NO;

        _ready =
            NO;

        _accessTokenExpiresAt =
            0;

        _presenceVersion =
            0;

        _presenceUpdateInFlight =
            NO;

        _presenceRetryScheduled =
            NO;
    }

    return self;
}


// MARK: =========================================
// MARK: Status callbacks
// MARK: =========================================

- (void)notifyReady:(BOOL)ready
               text:(NSString *)text {

    _ready =
        ready;

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            if (self.onStatusChanged) {
                self.onStatusChanged(
                    ready,
                    text
                );
            }
        }
    );
}


- (void)notifyPresenceResultForID:
            (NSString *)presenceID
                              success:
            (BOOL)success {

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            if (self.onPresenceResult) {
                self.onPresenceResult(
                    presenceID,
                    success
                );
            }
        }
    );
}


// MARK: =========================================
// MARK: Client
// MARK: =========================================

- (void)ensureClient {
    if (_client) {
        return;
    }

    _client =
        std::make_shared<
            discordpp::Client
        >();

    __weak DiscordBridge *weakSelf =
        self;


    _client->SetStatusChangedCallback(

        [weakSelf](
            discordpp::Client::Status status,
            discordpp::Client::Error error,
            int32_t errorDetail
        ) {

            DiscordBridge *selfRef =
                weakSelf;

            if (!selfRef) {
                return;
            }


            if (
                status ==
                discordpp::Client::Status::Ready
            ) {
                [selfRef
                    notifyReady:YES
                    text:@"接続済み"
                ];

                dispatch_async(
                    dispatch_get_main_queue(),
                    ^{
                        [selfRef
                            sendPendingPresenceIfPossible
                        ];
                    }
                );

                return;
            }


            if (
                status ==
                discordpp::Client::Status::Connecting
            ) {
                [selfRef
                    notifyReady:NO
                    text:@"Discord 接続中"
                ];

                return;
            }


            if (
                status ==
                discordpp::Client::Status::Connected
            ) {
                [selfRef
                    notifyReady:NO
                    text:@"Discord 初期化中"
                ];

                return;
            }


            if (
                status ==
                discordpp::Client::Status::Reconnecting
            ) {
                [selfRef
                    notifyReady:NO
                    text:@"Discord 再接続中"
                ];

                return;
            }


            if (
                status ==
                discordpp::Client::Status::Disconnecting
            ) {
                [selfRef
                    notifyReady:NO
                    text:@"Discord 切断中"
                ];

                return;
            }


            if (
                status ==
                discordpp::Client::Status::HttpWait
            ) {
                [selfRef
                    notifyReady:NO
                    text:@"Discord 通信待ち"
                ];

                return;
            }


            if (
                status ==
                discordpp::Client::Status::Disconnected
            ) {
                NSString *message =
                    @"Discord 切断 / 復旧待ち";

                if (
                    error !=
                    discordpp::Client::Error::None
                ) {
                    message =
                        [NSString
                            stringWithFormat:
                                @"Discord 切断 (%d)",
                                errorDetail
                        ];
                }

                [selfRef
                    notifyReady:NO
                    text:message
                ];

                dispatch_after(
                    dispatch_time(
                        DISPATCH_TIME_NOW,
                        (int64_t)(
                            2.0 *
                            NSEC_PER_SEC
                        )
                    ),
                    dispatch_get_main_queue(),
                    ^{
                        [selfRef
                            reconnectIfNeeded
                        ];
                    }
                );

                return;
            }
        }
    );


    _client->SetTokenExpirationCallback(

        [weakSelf]() {
            DiscordBridge *selfRef =
                weakSelf;

            if (!selfRef) {
                return;
            }

            dispatch_async(
                dispatch_get_main_queue(),
                ^{
                    [selfRef
                        refreshStoredToken
                    ];
                }
            );
        }
    );
}


// MARK: =========================================
// MARK: Load stored token
// MARK: =========================================

- (void)loadStoredTokensIfNeeded {
    if (_applicationID == 0) {
        return;
    }

    if (
        _tokensLoadedForApplicationID ==
        _applicationID
    ) {
        return;
    }

    _tokensLoadedForApplicationID =
        _applicationID;

    _accessToken.clear();
    _refreshToken.clear();
    _accessTokenExpiresAt =
        0;

    NSDictionary *payload =
        LoadTokenPayload(
            _applicationID
        );

    if (!payload) {
        return;
    }

    NSString *accessToken =
        payload[@"accessToken"];

    NSString *refreshToken =
        payload[@"refreshToken"];

    NSNumber *expiresAt =
        payload[@"expiresAt"];


    if (
        [accessToken
            isKindOfClass:[NSString class]
        ]
    ) {
        _accessToken =
            NSStringToString(
                accessToken
            );
    }


    if (
        [refreshToken
            isKindOfClass:[NSString class]
        ]
    ) {
        _refreshToken =
            NSStringToString(
                refreshToken
            );
    }


    if (
        [expiresAt
            isKindOfClass:[NSNumber class]
        ]
    ) {
        _accessTokenExpiresAt =
            expiresAt.doubleValue;
    }
}


// MARK: =========================================
// MARK: Save token
// MARK: =========================================

- (void)saveTokensWithAccessToken:
            (NSString *)accessToken
                    refreshToken:
            (NSString *)refreshToken
                       expiresIn:
            (int32_t)expiresIn {

    if (_applicationID == 0) {
        return;
    }

    _accessToken =
        NSStringToString(
            accessToken
        );

    _refreshToken =
        NSStringToString(
            refreshToken
        );

    NSTimeInterval now =
        [NSDate date]
            .timeIntervalSince1970;

    _accessTokenExpiresAt =
        now +
        MAX(
            expiresIn,
            0
        );

    NSDictionary *payload = @{
        @"accessToken":
            accessToken ?: @"",

        @"refreshToken":
            refreshToken ?: @"",

        @"expiresAt":
            @(_accessTokenExpiresAt)
    };

    BOOL saved =
        SaveTokenPayload(
            _applicationID,
            payload
        );

    if (!saved) {
        NSLog(
            @"Discord token Keychain save failed"
        );
    }
}


// MARK: =========================================
// MARK: Clear tokens
// MARK: =========================================

- (void)clearStoredTokens {
    if (_applicationID != 0) {
        DeleteTokenPayload(
            _applicationID
        );
    }

    _accessToken.clear();
    _refreshToken.clear();
    _accessTokenExpiresAt =
        0;
}


// MARK: =========================================
// MARK: Token state
// MARK: =========================================

- (BOOL)shouldRefreshToken {
    if (_refreshToken.empty()) {
        return NO;
    }

    if (_accessToken.empty()) {
        return YES;
    }

    if (_accessTokenExpiresAt <= 0) {
        return YES;
    }

    NSTimeInterval now =
        [NSDate date]
            .timeIntervalSince1970;

    const double refreshWindow =
        24.0 *
        60.0 *
        60.0;

    return
        _accessTokenExpiresAt <=
        now + refreshWindow;
}


// MARK: =========================================
// MARK: Start
// MARK: =========================================

- (void)startWithApplicationID:
            (uint64_t)applicationID {

    if (applicationID == 0) {
        [self
            notifyReady:NO
            text:@"DISCORD_APP_ID が未設定"
        ];

        return;
    }


    if (
        _applicationID !=
        applicationID
    ) {
        _applicationID =
            applicationID;

        _tokensLoadedForApplicationID =
            0;

        _accessToken.clear();
        _refreshToken.clear();

        _accessTokenExpiresAt =
            0;
    }


    [self ensureClient];

    _client->SetApplicationId(
        applicationID
    );

    [self loadStoredTokensIfNeeded];


    discordpp::Client::Status status =
        _client->GetStatus();


    if (
        status ==
        discordpp::Client::Status::Ready
    ) {
        [self
            notifyReady:YES
            text:@"接続済み"
        ];

        [self
            sendPendingPresenceIfPossible
        ];

        return;
    }


    if (
        status ==
            discordpp::Client::Status::Connecting
        ||
        status ==
            discordpp::Client::Status::Connected
        ||
        status ==
            discordpp::Client::Status::Reconnecting
        ||
        status ==
            discordpp::Client::Status::Disconnecting
        ||
        status ==
            discordpp::Client::Status::HttpWait
    ) {
        return;
    }


    if (
        _authorizationRunning ||
        _tokenOperationRunning
    ) {
        return;
    }


    if ([self shouldRefreshToken]) {
        [self refreshStoredToken];
        return;
    }


    if (!_accessToken.empty()) {
        [self
            applyStoredAccessTokenAndConnect
        ];

        return;
    }


    if (!_refreshToken.empty()) {
        [self refreshStoredToken];
        return;
    }


    [self beginAuthorization];
}


// MARK: =========================================
// MARK: Restore access token
// MARK: =========================================

- (void)applyStoredAccessTokenAndConnect {
    if (
        !_client ||
        _accessToken.empty()
    ) {
        return;
    }

    if (_tokenOperationRunning) {
        return;
    }

    _tokenOperationRunning =
        YES;

    [self
        notifyReady:NO
        text:@"保存済みDiscord認証を復元中"
    ];

    std::string accessToken =
        _accessToken;

    __weak DiscordBridge *weakSelf =
        self;


    _client->UpdateToken(
        discordpp::
            AuthorizationTokenType::Bearer,
        accessToken,
        [weakSelf](
            discordpp::ClientResult result
        ) {
            DiscordBridge *selfRef =
                weakSelf;

            if (!selfRef) {
                return;
            }

            selfRef->
                _tokenOperationRunning =
                NO;

            if (!result.Successful()) {
                NSLog(
                    @"Stored UpdateToken failed: %s",
                    result.ToString().c_str()
                );

                if (
                    !selfRef->
                        _refreshToken.empty()
                ) {
                    dispatch_async(
                        dispatch_get_main_queue(),
                        ^{
                            [selfRef
                                refreshStoredToken
                            ];
                        }
                    );
                } else {
                    [selfRef
                        notifyReady:NO
                        text:@"Discord 再認証が必要"
                    ];
                }

                return;
            }

            if (!selfRef->_client) {
                return;
            }

            [selfRef
                notifyReady:NO
                text:@"Discord 自動接続中"
            ];

            selfRef->
                _client->
                Connect();
        }
    );
}


// MARK: =========================================
// MARK: Refresh token
// MARK: =========================================

- (void)refreshStoredToken {
    if (
        !_client ||
        _applicationID == 0
    ) {
        return;
    }

    if (
        _tokenOperationRunning ||
        _authorizationRunning
    ) {
        return;
    }

    [self loadStoredTokensIfNeeded];

    if (_refreshToken.empty()) {
        [self beginAuthorization];
        return;
    }

    _tokenOperationRunning =
        YES;

    [self
        notifyReady:NO
        text:@"Discord認証を自動更新中"
    ];

    uint64_t applicationID =
        _applicationID;

    std::string oldRefreshToken =
        _refreshToken;

    __weak DiscordBridge *weakSelf =
        self;


    _client->RefreshToken(
        applicationID,
        oldRefreshToken,

        [weakSelf](
            discordpp::ClientResult result,
            std::string accessToken,
            std::string refreshToken,
            discordpp::AuthorizationTokenType tokenType,
            int32_t expiresIn,
            std::string scopes
        ) {
            DiscordBridge *selfRef =
                weakSelf;

            if (!selfRef) {
                return;
            }

            selfRef->
                _tokenOperationRunning =
                NO;


            if (!result.Successful()) {
                NSLog(
                    @"RefreshToken failed: %s",
                    result.ToString().c_str()
                );

                if (result.Retryable()) {
                    NSTimeInterval delay =
                        result.RetryAfter();

                    if (delay < 2.0) {
                        delay = 5.0;
                    }

                    if (delay > 60.0) {
                        delay = 60.0;
                    }

                    [selfRef
                        scheduleRefreshRetry:delay
                    ];

                    return;
                }

                [selfRef clearStoredTokens];

                [selfRef
                    notifyReady:NO
                    text:@"Discord 再認証が必要"
                ];

                dispatch_after(
                    dispatch_time(
                        DISPATCH_TIME_NOW,
                        (int64_t)(
                            1.0 *
                            NSEC_PER_SEC
                        )
                    ),
                    dispatch_get_main_queue(),
                    ^{
                        [selfRef
                            beginAuthorization
                        ];
                    }
                );

                return;
            }


            if (
                accessToken.empty() ||
                refreshToken.empty()
            ) {
                [selfRef clearStoredTokens];

                [selfRef
                    notifyReady:NO
                    text:@"Discord 再認証が必要"
                ];

                dispatch_async(
                    dispatch_get_main_queue(),
                    ^{
                        [selfRef
                            beginAuthorization
                        ];
                    }
                );

                return;
            }


            NSString *accessString =
                StringToNSString(
                    accessToken
                );

            NSString *refreshString =
                StringToNSString(
                    refreshToken
                );

            [selfRef
                saveTokensWithAccessToken:
                    accessString
                refreshToken:
                    refreshString
                expiresIn:
                    expiresIn
            ];


            if (!selfRef->_client) {
                return;
            }


            selfRef->
                _tokenOperationRunning =
                YES;


            selfRef->_client->UpdateToken(
                tokenType,
                accessToken,

                [weakSelf](
                    discordpp::ClientResult
                        updateResult
                ) {
                    DiscordBridge *self2 =
                        weakSelf;

                    if (!self2) {
                        return;
                    }

                    self2->
                        _tokenOperationRunning =
                        NO;

                    if (
                        !updateResult.Successful()
                    ) {
                        NSLog(
                            @"Refreshed UpdateToken failed: %s",
                            updateResult
                                .ToString()
                                .c_str()
                        );

                        return;
                    }

                    if (!self2->_client) {
                        return;
                    }

                    discordpp::Client::Status status =
                        self2->
                            _client->
                            GetStatus();


                    if (
                        status ==
                        discordpp::Client::Status::Ready
                    ) {
                        [self2
                            notifyReady:YES
                            text:@"接続済み"
                        ];

                        [self2
                            sendPendingPresenceIfPossible
                        ];

                        return;
                    }


                    if (
                        status ==
                        discordpp::Client::Status::Disconnected
                    ) {
                        [self2
                            notifyReady:NO
                            text:@"Discord 再接続中"
                        ];

                        self2->
                            _client->
                            Connect();
                    }
                }
            );
        }
    );
}


// MARK: =========================================
// MARK: Refresh retry
// MARK: =========================================

- (void)scheduleRefreshRetry:
            (NSTimeInterval)delay {

    if (delay < 1.0) {
        delay =
            1.0;
    }

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(
                delay *
                NSEC_PER_SEC
            )
        ),
        dispatch_get_main_queue(),
        ^{
            [self
                refreshStoredToken
            ];
        }
    );
}


// MARK: =========================================
// MARK: Authorization
// MARK: =========================================

- (void)beginAuthorization {
    if (
        !_client ||
        _applicationID == 0
    ) {
        return;
    }

    if (
        _authorizationRunning ||
        _tokenOperationRunning
    ) {
        return;
    }

    _authorizationRunning =
        YES;

    [self
        notifyReady:NO
        text:@"Discord 初回認証"
    ];


    auto verifier =
        _client->
            CreateAuthorizationCodeVerifier();

    discordpp::AuthorizationArgs
        args{};

    args.SetClientId(
        _applicationID
    );

    args.SetScopes(
        discordpp::Client::
            GetDefaultPresenceScopes()
    );

    args.SetCodeChallenge(
        verifier.Challenge()
    );


    uint64_t applicationID =
        _applicationID;

    __weak DiscordBridge *weakSelf =
        self;


    _client->Authorize(
        args,

        [
            weakSelf,
            verifier,
            applicationID
        ](
            discordpp::ClientResult result,
            std::string code,
            std::string redirectUri
        ) {
            DiscordBridge *selfRef =
                weakSelf;

            if (!selfRef) {
                return;
            }

            if (!result.Successful()) {
                selfRef->
                    _authorizationRunning =
                    NO;

                [selfRef
                    notifyReady:NO
                    text:@"Discord 認証失敗"
                ];

                return;
            }

            if (!selfRef->_client) {
                selfRef->
                    _authorizationRunning =
                    NO;

                return;
            }


            selfRef->_client->GetToken(
                applicationID,
                code,
                verifier.Verifier(),
                redirectUri,

                [weakSelf](
                    discordpp::ClientResult tokenResult,
                    std::string accessToken,
                    std::string refreshToken,
                    discordpp::AuthorizationTokenType tokenType,
                    int32_t expiresIn,
                    std::string scopes
                ) {
                    DiscordBridge *self2 =
                        weakSelf;

                    if (!self2) {
                        return;
                    }

                    self2->
                        _authorizationRunning =
                        NO;

                    if (
                        !tokenResult.Successful()
                    ) {
                        [self2
                            notifyReady:NO
                            text:@"Discord Token取得失敗"
                        ];

                        return;
                    }


                    NSString *accessString =
                        StringToNSString(
                            accessToken
                        );

                    NSString *refreshString =
                        StringToNSString(
                            refreshToken
                        );


                    [self2
                        saveTokensWithAccessToken:
                            accessString
                        refreshToken:
                            refreshString
                        expiresIn:
                            expiresIn
                    ];


                    if (!self2->_client) {
                        return;
                    }


                    self2->
                        _tokenOperationRunning =
                        YES;


                    self2->_client->UpdateToken(
                        tokenType,
                        accessToken,

                        [weakSelf](
                            discordpp::ClientResult
                                updateResult
                        ) {
                            DiscordBridge *self3 =
                                weakSelf;

                            if (!self3) {
                                return;
                            }

                            self3->
                                _tokenOperationRunning =
                                NO;

                            if (
                                !updateResult.Successful()
                            ) {
                                NSLog(
                                    @"Initial UpdateToken failed: %s",
                                    updateResult
                                        .ToString()
                                        .c_str()
                                );

                                [self3
                                    notifyReady:NO
                                    text:@"Discord Token設定失敗"
                                ];

                                return;
                            }

                            if (!self3->_client) {
                                return;
                            }

                            [self3
                                notifyReady:NO
                                text:@"Discord 接続中"
                            ];

                            self3->
                                _client->
                                Connect();
                        }
                    );
                }
            );
        }
    );
}


// MARK: =========================================
// MARK: Reconnect
// MARK: =========================================

- (void)reconnectIfNeeded {
    if (
        !_client ||
        _applicationID == 0
    ) {
        return;
    }


    discordpp::Client::Status status =
        _client->GetStatus();


    if (
        status ==
        discordpp::Client::Status::Ready
    ) {
        if (!_ready) {
            [self
                notifyReady:YES
                text:@"接続済み"
            ];
        }

        [self
            sendPendingPresenceIfPossible
        ];

        return;
    }


    if (
        status ==
            discordpp::Client::Status::Connecting
        ||
        status ==
            discordpp::Client::Status::Connected
        ||
        status ==
            discordpp::Client::Status::Reconnecting
        ||
        status ==
            discordpp::Client::Status::Disconnecting
        ||
        status ==
            discordpp::Client::Status::HttpWait
    ) {
        return;
    }


    if (
        _authorizationRunning ||
        _tokenOperationRunning
    ) {
        return;
    }


    [self loadStoredTokensIfNeeded];


    if ([self shouldRefreshToken]) {
        [self refreshStoredToken];
        return;
    }


    if (_client->IsAuthenticated()) {
        [self
            notifyReady:NO
            text:@"Discord 再接続中"
        ];

        _client->Connect();

        return;
    }


    if (!_accessToken.empty()) {
        [self
            applyStoredAccessTokenAndConnect
        ];

        return;
    }


    if (!_refreshToken.empty()) {
        [self refreshStoredToken];
        return;
    }


    [self beginAuthorization];
}


// MARK: =========================================
// MARK: Callbacks
// MARK: =========================================

- (void)runCallbacks {
    discordpp::RunCallbacks();
}


// MARK: =========================================
// MARK: Update presence
// MARK: =========================================

- (void)updatePresenceWithTitle:
            (NSString *)title
                         artist:
            (NSString *)artist
                          album:
            (NSString *)album
                        songURL:
            (NSString * _Nullable)songURL
                     artworkURL:
            (NSString * _Nullable)artworkURL
                     presenceID:
            (NSString *)presenceID
                 startTimestamp:
            (int64_t)startTimestamp
                   endTimestamp:
            (int64_t)endTimestamp {

    _presenceVersion +=
        1;

    _pendingPresence.valid =
        true;

    _pendingPresence.version =
        _presenceVersion;

    _pendingPresence.presenceID =
        NSStringToString(
            presenceID
        );

    _pendingPresence.title =
        NSStringToString(
            title
        );

    _pendingPresence.artist =
        NSStringToString(
            artist
        );

    _pendingPresence.album =
        NSStringToString(
            album
        );

    _pendingPresence.songURL =
        NSStringToOptionalString(
            songURL
        );

    _pendingPresence.artworkURL =
        NSStringToOptionalString(
            artworkURL
        );

    _pendingPresence.startTimestamp =
        startTimestamp;

    _pendingPresence.endTimestamp =
        endTimestamp;


    [self
        sendPendingPresenceIfPossible
    ];
}


// MARK: =========================================
// MARK: Presence retry
// MARK: =========================================

- (void)schedulePresenceRetry:
            (NSTimeInterval)delay {

    if (_presenceRetryScheduled) {
        return;
    }

    if (delay < 1.0) {
        delay =
            2.0;
    }

    if (delay > 60.0) {
        delay =
            60.0;
    }

    _presenceRetryScheduled =
        YES;

    __weak DiscordBridge *weakSelf =
        self;


    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(
                delay *
                NSEC_PER_SEC
            )
        ),
        dispatch_get_main_queue(),
        ^{
            DiscordBridge *selfRef =
                weakSelf;

            if (!selfRef) {
                return;
            }

            selfRef->
                _presenceRetryScheduled =
                NO;

            [selfRef
                sendPendingPresenceIfPossible
            ];
        }
    );
}


// MARK: =========================================
// MARK: Send presence
// MARK: =========================================

- (void)sendPendingPresenceIfPossible {
    if (!_client) {
        return;
    }

    if (!_pendingPresence.valid) {
        return;
    }

    if (
        _client->GetStatus() !=
        discordpp::Client::Status::Ready
    ) {
        return;
    }

    if (_presenceUpdateInFlight) {
        return;
    }

    if (_presenceRetryScheduled) {
        return;
    }


    const PendingPresence presence =
        _pendingPresence;

    const uint64_t sentVersion =
        presence.version;

    const std::string sentPresenceID =
        presence.presenceID;


    _presenceUpdateInFlight =
        YES;


    discordpp::Activity activity;


    /*
     「diさんを再生中」の
     diさん部分をApple Musicへ。
     */
    activity.SetName(
        "Apple Music"
    );


    activity.SetType(
        discordpp::
            ActivityTypes::Listening
    );


    /*
     ステータス文字列は曲名。
     */
    activity.SetStatusDisplayType(
        discordpp::
            StatusDisplayTypes::Details
    );


    // MARK: Track title

    if (
        presence.title.length() >= 2
    ) {
        activity.SetDetails(
            presence.title
        );
    } else {
        std::string safeTitle =
            "♪ " +
            presence.title;

        activity.SetDetails(
            safeTitle
        );
    }


    // MARK: Artist

    if (
        presence.artist.length() >= 2
    ) {
        activity.SetState(
            presence.artist
        );
    } else if (
        !presence.artist.empty()
    ) {
        std::string safeArtist =
            "Artist: " +
            presence.artist;

        activity.SetState(
            safeArtist
        );
    }


    // MARK: Apple Music URL

    if (
        presence.songURL.has_value()
    ) {
        const std::string &url =
            presence.songURL.value();

        if (
            url.length() >= 2 &&
            url.length() <= 256
        ) {
            activity.SetDetailsUrl(
                url
            );
        }
    }


    // MARK: Timestamps

    discordpp::ActivityTimestamps
        timestamps;

    if (
        presence.startTimestamp > 0
    ) {
        timestamps.SetStart(
            presence.startTimestamp
        );
    }

    if (
        presence.endTimestamp >
        presence.startTimestamp
    ) {
        timestamps.SetEnd(
            presence.endTimestamp
        );
    }

    activity.SetTimestamps(
        timestamps
    );


    // MARK: Artwork

    discordpp::ActivityAssets
        assets;

    if (
        presence.artworkURL.has_value()
    ) {
        const std::string &artwork =
            presence.artworkURL.value();

        if (
            !artwork.empty() &&
            artwork.length() <= 300
        ) {
            assets.SetLargeImage(
                artwork
            );
        } else {
            assets.SetLargeImage(
                "applemusic"
            );
        }
    } else {
        assets.SetLargeImage(
            "applemusic"
        );
    }


    // MARK: Album

    if (
        presence.album.length() >= 2 &&
        presence.album.length() <= 128
    ) {
        assets.SetLargeText(
            presence.album
        );
    }


    activity.SetAssets(
        assets
    );


    __weak DiscordBridge *weakSelf =
        self;


    _client->UpdateRichPresence(
        activity,

        [
            weakSelf,
            sentVersion,
            sentPresenceID
        ](
            discordpp::ClientResult result
        ) {
            DiscordBridge *selfRef =
                weakSelf;

            if (!selfRef) {
                return;
            }


            /*
             ClientResultの値は
             callback内で先に抜いておく。
             */
            const bool successful =
                result.Successful();

            const bool retryable =
                result.Retryable();

            const float retryAfter =
                result.RetryAfter();


            if (!successful) {
                NSLog(
                    @"UpdateRichPresence failed: %s",
                    result.ToString().c_str()
                );

                NSLog(
                    @"Error: %s",
                    result.Error().c_str()
                );

                NSLog(
                    @"ErrorCode: %d",
                    result.ErrorCode()
                );

                NSLog(
                    @"Retryable: %s",
                    retryable
                        ? "YES"
                        : "NO"
                );

                NSLog(
                    @"RetryAfter: %.2f",
                    retryAfter
                );
            }


            dispatch_async(
                dispatch_get_main_queue(),
                ^{
                    selfRef->
                        _presenceUpdateInFlight =
                        NO;


                    NSString *presenceID =
                        StringToNSString(
                            sentPresenceID
                        );


                    /*
                     ここが今回の重要部分。

                     Discordから本当に成功した時だけ
                     success = YES をSwift側へ返す。
                     */
                    [selfRef
                        notifyPresenceResultForID:
                            presenceID
                        success:
                            successful
                    ];


                    // MARK: Success

                    if (successful) {
                        /*
                         送信している間に
                         次の曲へ変わっていたら
                         最新版を続けて送る。
                         */
                        if (
                            selfRef->
                                _pendingPresence.valid
                            &&
                            selfRef->
                                _pendingPresence.version
                            !=
                            sentVersion
                        ) {
                            [selfRef
                                sendPendingPresenceIfPossible
                            ];
                        }

                        return;
                    }


                    // MARK: Retryable failure

                    if (retryable) {
                        NSTimeInterval delay =
                            retryAfter;

                        if (delay < 1.0) {
                            delay =
                                2.0;
                        }

                        [selfRef
                            schedulePresenceRetry:
                                delay
                        ];

                        return;
                    }


                    /*
                     retry不可でも、
                     送信中に別の曲へ変わっていた場合は
                     新しい曲を送る。

                     同じ壊れたPresenceを
                     無限連打するのは避ける。
                     */
                    if (
                        selfRef->
                            _pendingPresence.valid
                        &&
                        selfRef->
                            _pendingPresence.version
                        !=
                        sentVersion
                    ) {
                        [selfRef
                            sendPendingPresenceIfPossible
                        ];
                    }
                }
            );
        }
    );
}


// MARK: =========================================
// MARK: Clear presence
// MARK: =========================================

- (void)clearPresence {
    _presenceVersion +=
        1;

    _pendingPresence.valid =
        false;

    _pendingPresence.version =
        _presenceVersion;

    _pendingPresence.presenceID.clear();

    if (!_client) {
        return;
    }

    if (
        _client->GetStatus() !=
        discordpp::Client::Status::Ready
    ) {
        return;
    }

    _client->ClearRichPresence();
}

@end
