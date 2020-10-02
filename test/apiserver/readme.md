Commands used to create this apiserver. Create an initial service then add a resource type (CRD) to expose. v1alpha1/example.infoblox.com/Contact


    apiserver-boot init repo --domain example.infoblox.com
    apiserver-boot create group --group contact version --version v1alpha1 resource --kind Contact
