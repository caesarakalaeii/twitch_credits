'''
To use this script create a file called credentials.json with the following content:
{
    "client_id": "YOUR_CLIENT_ID",
    "auth_token": "YOUR_AUTH_TOKEN",
    "channel_name": "YOUR_CHANNEL_NAME",
    "redemption_id": "REDEEM_ID", 
    "functions": {
      "new_subs": true,
      "new_follows": true,
      "new_raids": true,
      "all_subs": true,
      "redeem": true

    }
  }
  
  You can turn features off/and on by changing the values from true to false
'''

import json
from events import EventRecorder
from event_formatter import Formatter
from twitchAPI.twitch import Twitch
from twitchAPI.oauth import UserAuthenticator
from twitchAPI.types import AuthScope



class CreditBuilder(object):
    
    
    def __init__(self):
        functions = {"new_subs": [self.check_new_subs(), AuthScope.CHANNEL_READ_SUBSCRIPTIONS],
                     "new_follows": [self.check_follows()],
                     "new_raids": [self.check_raids()],
                     "all_subs": [AuthScope.CHANNEL_READ_SUBSCRIPTIONS],
                     "redeem": [self.check_new_redeems(), AuthScope.CHANNEL_READ_REDEMPTIONS]
                     }
        # Load credentials from JSON file
        with open('credentials.json') as f:
            self.credentials = json.load(f)

        self.desired_redemption_id = self.credentials['redemption_id']
        self.enabled_functions = []
        self.scope = []
        activate_functions = self.credentials['functions']
        #enable set functions
        for f,v in functions:
            if activate_functions[f]:
                if f is "all_subs":
                    self.scope.append(v[0])
                    continue #redundant but improves readability
                else:
                    self.enabled_functions.append(v[0])
                    try: #try to add scope, if it exists
                        self.scope.append(v[1])
                    except IndexError:
                        continue
                
            
        # Initialize the Twitch API client
        self.twitch = Twitch(self.credentials['client_id'], self.credentials['client_secret'])
        self.twitch.authenticate_app([])
        
        self.auth = UserAuthenticator(self.twitch, self.scope)
        self.token, _ = self.auth.authenticate()

        # Set the access token
        self.twitch.set_user_authentication(self.token, self.credentials['client_id'])

        # Get your user ID
        self.user_info = self.twitch.get_users(logins=[self.credentials['username']])
        self.user_id = self.user_info['data'][0]['id']

        # Track stream status
        self.stream_ended = False
        #set up Event recorder
        self.event_rec = EventRecorder()
        
        self.last_redemption_id = 0

    def build_file(self):
        if AuthScope.CHANNEL_READ_SUBSCRIPTIONS in self.scope:
            self.event_rec.set_subs(self.get_active_subscriptions()) #gets all active subscriptions, duplicates are handled
        Formatter.write_events(self.event_rec.get_events)

    def check_stream_status(self):
        global stream_ended
        stream = self.twitch.get_streams(user_id=self.user_id)
        if stream['data']:
            if not stream_ended:
                print("Stream is live!")
                # Perform actions for stream start
            stream_ended = False
        else:
            if not stream_ended:
                print("Stream has ended!")
                # Perform actions for stream end
                self.build_file()
            stream_ended = True
            
    def check_raids(self):
        events = self.twitch.get_users_follows(from_id=self.user_id, first=1, event_type='raid')
        if events:
            raid = events['data'][0]
            if raid['from_id'] != last_raid_id:
                print(f"New raid: {raid['from_name']}")
                # Perform actions for new raid
                
            last_raid_id = raid['from_id']
    def check_follows(self):
        events = self.twitch.get_users_follows(from_id=self.user_id, first=1)
        if events:
            event = events['data'][0]
            if event['to_id'] == self.user_id:
                if event['followed_at'] != event['followed_at']:
                    print(f"New follower: {event['from_name']}")
                    # Perform actions for new follower
                    self.event_rec.set_new_follow(event['from_name'])
    def check_new_subs(self):
        subscriptions = self.twitch.get_subscriptions(broadcaster_id=self.user_id, first=1)
        if subscriptions:
            subscription = subscriptions['data'][0]
            if subscription['event_time'] != subscription['event_time']:
                print(f"New subscriber: {subscription['user_name']}")
                # Perform actions for new subscriber
                self.event_rec.set_new_sub(subscription['user_name'])
    def check_new_redeems(self):
        redemptions = self.twitch.get_custom_reward_redemptions(broadcaster_id=self.user_id, first=1)
        if redemptions:
            redemption = redemptions['data'][0]
            if redemption['id'] != self.last_redemption_id and redemption['reward']['id'] == self.desired_redemption_id:
                print(f"New redemption: {redemption['user']['login']}")
                # Perform actions for new redemption
            self.last_redemption_id = redemption['id']
            
    def get_active_subscriptions(self):
        usernames = []
        cursor = None
        while True:
            response = self.twitch.get_subscriptions(broadcaster_id=self.user_id, first=100, after=cursor)
            if response and response['data']:
                for sub in response['data']:
                    usernames.append(sub['user_name'])
            if 'pagination' in response and 'cursor' in response['pagination']:
                cursor = response['pagination']['cursor']
            else:
                break
        return usernames
                            
    def main(self):
        # Start listening to events
        while self.check_stream_status():
            try:
                for function in self.enabled_functions:
                    function
                
            except KeyboardInterrupt:
                self.build_file(self.event_rec)
                break
            except Exception as e:
                print(f"An error occurred: {str(e)}")
                
    