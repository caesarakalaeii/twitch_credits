import json
from events import EventRecorder
from event_formatter import Formatter
from twitchAPI.twitch import Twitch
from twitchAPI.oauth import UserAuthenticator
from twitchAPI.types import AuthScope

class CreditBuilder(object):
    def __init__(self):
        
        # Load credentials from JSON file
        with open('credentials.json') as f:
            self.credentials = json.load(f)

        # Initialize the Twitch API client
        self.twitch = Twitch(self.credentials['client_id'], self.credentials['client_secret'])
        self.twitch.authenticate_app([])
        self.auth = UserAuthenticator(self.twitch, [AuthScope.CHANNEL_READ_SUBSCRIPTIONS, AuthScope.CHANNEL_READ_REDEMPTIONS])
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

    def build_file(self):
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
    def main(self):
        #Set up Events
        

        # Start listening to events
        while self.check_stream_status():
            try:
                
                events = self.twitch.get_users_follows(from_id=self.user_id, first=1)
                if events:
                    event = events['data'][0]
                    if event['to_id'] == self.user_id:
                        if event['followed_at'] != event['followed_at']:
                            print(f"New follower: {event['from_name']}")
                            # Perform actions for new follower
                            self.event_rec.set_new_follow(event['from_name'])
                            
                subscriptions = self.twitch.get_subscriptions(broadcaster_id=self.user_id, first=1)
                if subscriptions:
                    subscription = subscriptions['data'][0]
                    if subscription['event_time'] != subscription['event_time']:
                        print(f"New subscriber: {subscription['user_name']}")
                        # Perform actions for new subscriber
                        self.event_rec.set_new_sub(subscription['user_name'])
                redemptions = self.twitch.get_custom_reward_redemptions(broadcaster_id=self.user_id, first=1)
                if redemptions:
                    redemption = redemptions['data'][0]
                    if redemption['redeemed_at'] != redemption['redeemed_at']:
                        print(f"New redemption: {redemption['user']['login']}")
                        # Perform actions for new redemption
                        self.event_rec.set_new_redeem(redemption['user']['login'])
            except KeyboardInterrupt:
                self.build_file(self.event_rec)
                break
            except Exception as e:
                print(f"An error occurred: {str(e)}")