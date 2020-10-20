Commands used to create this apiserver. Create an initial service then add a resource type (CRD) to expose. v1alpha1/example.infoblox.com/Contact


    apiserver-boot init repo --domain infoblox.com
    apiserver-boot create group version resource --group example version --version v1alpha1 --kind Contact
