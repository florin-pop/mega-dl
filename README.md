# mega-dl

Command line utility to download from Mega.nz

## What's the purpose of this project?

It is a proof of concept for using https://github.com/florin-pop/MegaKit

It aims to eventually implement resumable downloads from the command line, but this is currently a challenge as `URLSession` cannot resume some downloads from mega.nz

## Usage

```
mega-dl 'https://mega.nz/file/nyIECKrQ#c3tzkRH1OtQ-cxvOc26B9TkwXy9MNdRpciaOjq-0B6o'
```

For downloads that exceed 5GB, configure your Mega.nz credentials as follows:

 * Create a file in your home directory named `mega.rc`:
 ```
 nano ~/.megarc 
 ```
 * Add the following content:
 ```
 [Login]
Username = email@test.com
Password = 123456
 ```
 * Change the email and password to match your login credentials.
 
