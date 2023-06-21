'''
Utility class to format the recorded Events
'''

class Formatter(object):
    
    def write_events(events):
        with open("credits.txt", "w") as file:
            for event, users in events:
                file.write(f"{event}\n")
                for user in users:
                    file.write(f"{user}, ")