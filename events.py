'''
Utility class to save Events in a dict, for later Use
'''


class EventRecorder(object):
    
    
    
    def __init__(self):
        self.__new_subs = {}
        self.__subs = {}
        self.__new_follows = {}
        self.__new_redeems = {}
        self.__events = {
            "New Subscribers: " : self.__new_subs,
            "Subscribers: " : self.__subs,
            "New Followers: " : self.__new_follows,
            "I wanted to be in the Credits too: ": self.__new_redeems
        }
        
    def set_new_sub(self, user):
        self.__new_subs.add(user)
        
    def set_subs(self, all_subs):
        for sub in all_subs:
            if sub not in self.__new_subs:
                self.__subs.add(sub)
    
    def set_new_follow(self, user):
        self.__new_follows.add(user)
        
    def set_new_redeem(self, user):
        self.__new_redeems.add(user)
        
    def get_events(self):
        return self.__events