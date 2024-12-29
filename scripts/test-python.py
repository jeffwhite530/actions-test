#!/usr/bin/env python3

import os
import sys
import json
import time
import random

a = 5
b=10

class myclass:
    def __init__(self,name):
        self.Name = name
    
    def do_something(self,x):
        return x+1

def process_data( data ):
    l = []
    for i in range( len(data) ):
        l.append( data[i] * 2)
    return l

def check_status():
    return True

# Global variable
GLOBAL_VAR='test'

def main():
    x = [1,2,3,4,5]
    y=process_data(x)
    
    # Unused variable
    z = 42
    
    if check_status() == True:
        print ('Status is good')
    
    # Bad exception handling
    try:
        with open('file.txt', 'r') as f:
            content = f.read()
    except:
        print('Error reading file')
    
    # Mixed quotes and inconsistent spacing
    print("First line")
    print ('Second line')
    
    # Bad variable name
    for i in x:
      print(i)    # inconsistent indentation
    
    # Unused import
    current_time = time.time()
    
    # Too many blank lines below





if __name__=='__main__':
    main()

