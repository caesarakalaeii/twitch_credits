'''
Utility class to save Events in a dict, for later Use
'''


class EventRecorder(object):
    
    
    
    def __init__(self):
        self.raids = []
        self.__new_subs = []
        self.__subs = []
        self.__new_follows = []
        self.__new_redeems = []
        self.__events = {
            "Raiders": self.raids,
            "New Subscribers" : self.__new_subs,
            "Subscribers" : self.__subs,
            "New Followers" : self.__new_follows,
            "I wanted to be in the Credits too": self.__new_redeems
        }
        
    def set_new_sub(self, user):
        self.__new_subs.append(user)
        
    def set_subs(self, all_subs):
        for sub in all_subs:
            if sub not in self.__new_subs:
                self.__subs.append(sub)
    
    def set_new_follow(self, user):
        self.__new_follows.append(user)
        
    def set_new_redeem(self, user):
        self.__new_redeems.append(user)
        
    def get_events(self):
        return self.__events